#!/usr/bin/env python3
"""Elección del servidor primario con etcd, que usa el algoritmo de consenso Raft.

Solo usa la biblioteca estándar. Habla con etcd por su API HTTP y JSON.

El primario es quien tiene la llave /sad-lab/primario en etcd. La llave vive atada a un
lease, un contrato que vence en LEASE_TTL segundos si no se renueva. Por eso:

  * Si el primario cae, deja de renovar, la llave desaparece sola y otro servidor asume.
  * Si el primario queda aislado de la mayoría de etcd, no puede renovar. A un tercio del
    plazo se pone solo en solo lectura (fencing), antes de que otro pueda asumir. Así nunca
    hay dos servidores aceptando escrituras.
  * La revisión de etcd en que se creó la llave es la época del primario. Crece siempre,
    sirve de ficha de fencing y la muestra el agente de estado.
  * El orden de SERVERS se respeta: cada servidor espera RANK_DELAY segundos por cada
    puesto que tiene delante antes de postularse.
  * Solo se postula quien tiene los datos más nuevos: el último primario o una réplica cuyo
    latido trae la época del último primario. Un servidor que estuvo caído no vuelve a
    mandar con datos viejos. Si en STALE_GRACE segundos nadie al día asume, se relaja.

Uso
  elector.py run                 bucle del servicio sad-elector en cada servidor
  elector.py status [--json]     primario, época, reserva y miembros de etcd
  elector.py leader              imprime solo el nombre del primario actual
  elector.py reserve NODO SEG    reserva el puesto para NODO, lo usa el failback
  elector.py unreserve           quita la reserva
  elector.py stepdown            pide al elector local que ceda el puesto y espera
"""
from __future__ import annotations

import base64
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

KEY = "/sad-lab/primario"
RESERVE_KEY = "/sad-lab/reserva"
LAST_KEY = "/sad-lab/ultimo"
CONF_FILES = os.environ.get("SAD_CONF", "/etc/sad-lab/lab.conf:/etc/sad-lab/derived.conf").split(":")


def load_conf() -> dict:
    """Lee lab.conf y derived.conf. Basta con KEY=valor, con o sin comillas."""
    env: dict = {}
    for path in CONF_FILES:
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except OSError:
            continue
        for line in lines:
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if not m:
                continue
            val = m.group(2).strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            env[m.group(1)] = val
    for key, val in os.environ.items():
        if key.startswith("SAD_OVERRIDE_"):
            env[key[len("SAD_OVERRIDE_"):]] = val
    return env


def b64(text: str) -> str:
    return base64.b64encode(text.encode()).decode()


def unb64(text: str) -> str:
    return base64.b64decode(text).decode()


class EtcdError(Exception):
    pass


class Etcd:
    """Cliente mínimo de la API v3 de etcd por HTTP."""

    def __init__(self, endpoints: list[str], timeout: float = 1.5):
        self.endpoints = [e.rstrip("/") for e in endpoints if e]
        self.timeout = timeout

    def call(self, path: str, body: dict) -> dict:
        # Presupuesto total de tiempo. Si un miembro no responde no se espera a cada uno
        # por separado, así el primario detecta a tiempo que perdió la mayoría.
        last = None
        deadline = time.monotonic() + self.timeout
        for i, ep in enumerate(list(self.endpoints)):
            left = deadline - time.monotonic()
            if left <= 0.05:
                break
            req = urllib.request.Request(ep + path, data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=left) as resp:
                    data = json.loads(resp.read() or b"{}")
            except (urllib.error.URLError, OSError, ValueError) as exc:
                last = exc
                continue
            if "error" in data and "header" not in data:
                last = EtcdError(data.get("error"))
                continue
            if i:  # el que respondió pasa al frente
                self.endpoints.insert(0, self.endpoints.pop(i))
            return data
        raise EtcdError(f"ningún miembro de etcd respondió: {last}")

    def get(self, key: str) -> dict | None:
        data = self.call("/v3/kv/range", {"key": b64(key)})
        kvs = data.get("kvs") or []
        if not kvs:
            return None
        kv = kvs[0]
        try:
            value = json.loads(unb64(kv.get("value", "")))
        except ValueError:
            value = {}
        return {"value": value, "create_revision": int(kv.get("create_revision", 0)),
                "lease": str(kv.get("lease", "0"))}

    def grant(self, ttl: int) -> str:
        return str(self.call("/v3/lease/grant", {"TTL": ttl})["ID"])

    def keepalive(self, lease: str) -> int:
        data = self.call("/v3/lease/keepalive", {"ID": lease})
        return int((data.get("result") or {}).get("TTL", 0))

    def revoke(self, lease: str) -> None:
        self.call("/v3/lease/revoke", {"ID": lease})

    def create(self, key: str, value: dict, lease: str) -> tuple[bool, int]:
        """Crea la llave solo si no existe. Devuelve si lo logró y la revisión."""
        data = self.call("/v3/kv/txn", {
            "compare": [{"key": b64(key), "target": "CREATE", "create_revision": "0"}],
            "success": [{"request_put": {"key": b64(key), "value": b64(json.dumps(value)), "lease": lease}}],
        })
        return bool(data.get("succeeded")), int(data.get("header", {}).get("revision", 0))

    def put(self, key: str, value: dict, lease: str | None = None) -> None:
        body = {"key": b64(key), "value": b64(json.dumps(value))}
        if lease:
            body["lease"] = lease
        self.call("/v3/kv/put", body)

    def delete(self, key: str) -> None:
        self.call("/v3/kv/deleterange", {"key": b64(key)})

    def members(self) -> list[dict]:
        return self.call("/v3/cluster/member/list", {}).get("members") or []

    def raft_leader(self) -> str:
        """Nombre del miembro de etcd que hoy es líder de Raft."""
        st = self.call("/v3/maintenance/status", {})
        leader = str(st.get("leader", ""))
        for m in self.members():
            if str(m.get("ID")) == leader:
                return m.get("name", leader)
        return leader


def endpoints_from(conf: dict) -> list[str]:
    return [e.strip() for e in conf.get("ETCD_ENDPOINTS", "").split(",") if e.strip()]


class Elector:
    def __init__(self, conf: dict):
        self.conf = conf
        self.me = conf["NODE_NAME"]
        self.servers = conf.get("SERVERS", "").split()
        self.ttl = int(conf.get("LEASE_TTL", "6") or 6)
        # Se aísla a un tercio del contrato. Con la espera de cada vuelta y de cada llamada
        # sigue quedando antes de que el contrato venza y otro pueda asumir.
        self.fence_after = self.ttl / 3
        self.rank_delay = float(conf.get("RANK_DELAY", "2") or 2)
        self.stale_grace = float(conf.get("STALE_GRACE", "30") or 30)
        self.absent_since = 0.0
        self.state = conf.get("STATE_DIR", "/var/lib/sad-lab")
        self.exports = conf.get("EXPORTS_FILE", "/etc/exports")
        self.export_dir = conf.get("EXPORT_DIR", "/srv/compartido")
        self.app_dir = conf.get("APP_DIR", "/opt/sad-app")
        self.log_file = conf.get("LOG_FILE", "/var/log/sad-lab.log")
        self.etcd = Etcd(endpoints_from(conf))
        self.leader = False
        self.lease: str | None = None
        self.last_ok = 0.0
        self.cooldown_until = 0.0
        self.last_leader = ""
        self.quiet: set = set()
        self.ticks = 0

    # ---------- utilidades ----------
    def path(self, name: str) -> str:
        return os.path.join(self.state, name)

    def say(self, msg: str) -> None:
        line = f"{time.strftime('%F %T')} [elector] {msg}"
        print(line, flush=True)
        try:
            with open(self.log_file, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def once(self, tag: str, msg: str) -> None:
        """Mensajes que se repetirían cada segundo, solo una vez hasta que cambie la situación."""
        if tag not in self.quiet:
            self.quiet.add(tag)
            self.say(msg)

    def run_cmd(self, *cmd: str) -> None:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    def set_export(self, mode: str) -> None:
        other = "ro" if mode == "rw" else "rw"
        try:
            text = open(self.exports, encoding="utf-8").read()
        except OSError:
            return
        new = "\n".join(
            ln.replace(f"({other},", f"({mode},") if ln.startswith(self.export_dir + " ") else ln
            for ln in text.split("\n"))
        if new != text:
            with open(self.exports, "w", encoding="utf-8") as fh:
                fh.write(new)
        self.run_cmd("exportfs", "-ra")

    def set_env_role(self, role: str) -> None:
        env = os.path.join(self.app_dir, ".env")
        try:
            text = open(env, encoding="utf-8").read()
        except OSError:
            return
        new = re.sub(r"(?m)^NODE_ROLE=.*$", f"NODE_ROLE={role}", text)
        if new != text:
            with open(env, "w", encoding="utf-8") as fh:
                fh.write(new)

    def write_leader(self, name: str) -> None:
        try:
            with open(self.path("leader"), "w", encoding="utf-8") as fh:
                fh.write(name + "\n")
        except OSError:
            pass

    # ---------- cambios de papel ----------
    def promote(self, epoch: int) -> None:
        self.say(f"Asumo como primario, época {epoch}")
        with open(self.path("primary"), "w", encoding="utf-8") as fh:
            fh.write(f"{epoch}\n")
        self.set_export("rw")
        snap = os.path.join(self.export_dir, ".cluster", "sad.db")
        if self.last_leader != self.me and os.path.exists(snap):
            self.run_cmd("systemctl", "stop", "sad-app")
            data = os.path.join(self.app_dir, "data")
            for suffix in ("", "-wal", "-shm"):
                try:
                    os.remove(os.path.join(data, "sad.db" + suffix))
                except OSError:
                    pass
            user = self.conf.get("LAB_USER", "sadlab")
            self.run_cmd("install", "-o", user, "-g", user, "-m", "640", snap, os.path.join(data, "sad.db"))
            self.say("Base de datos restaurada desde la última copia replicada")
        self.set_env_role("primario")
        self.run_cmd("systemctl", "enable", "--now", "sad-app")
        self.write_leader(self.me)
        self.last_leader = self.me
        try:
            self.etcd.put(LAST_KEY, {"node": self.me, "epoch": epoch})
        except EtcdError:
            pass
        self.say(f"{self.me} es el primario y replica hacia los demás servidores")

    def demote(self, reason: str) -> None:
        if not os.path.exists(self.path("primary")) and not self.leader:
            return
        self.say(f"Paso a réplica: {reason}")
        self.run_cmd("systemctl", "disable", "--now", "sad-app")
        try:
            os.remove(self.path("primary"))
        except OSError:
            pass
        self.set_export("ro")
        self.set_env_role("replica")
        self.leader = False

    # ---------- ciclo ----------
    def tick(self) -> None:
        self.ticks += 1
        if self.leader:
            self.renew()
        else:
            self.follow_or_campaign()

    def renew(self) -> None:
        if os.path.exists(self.path("stepdown")):
            try:
                os.remove(self.path("stepdown"))
            except OSError:
                pass
            try:
                if self.lease:
                    self.etcd.revoke(self.lease)
            except EtcdError:
                pass
            self.cooldown_until = time.time() + max(20.0, 3 * self.ttl)
            self.demote("cedo el puesto a pedido")
            return
        try:
            if self.lease and self.etcd.keepalive(self.lease) > 0:
                self.last_ok = time.time()
                self.quiet.discard("renew")
            if self.ticks % 3 == 0:
                kv = self.etcd.get(KEY)
                if not kv or kv["value"].get("node") != self.me or kv["lease"] != str(self.lease):
                    self.demote("la llave de primario ya no es mía")
                    return
        except EtcdError as exc:
            self.once("renew", f"No pude renovar el contrato: {exc}")
        silent = time.time() - self.last_ok
        if silent > self.fence_after:
            # Fencing. El contrato vence en LEASE_TTL. A la mitad este servidor ya dejó de
            # aceptar escrituras, así que cuando otro asuma no habrá dos primarios.
            self.demote(f"sin contacto con la mayoría de etcd hace {silent:.1f} s, me aíslo en solo lectura")

    def follow_or_campaign(self) -> None:
        try:
            kv = self.etcd.get(KEY)
        except EtcdError:
            self.once("noquorum", "etcd no tiene mayoría o no responde. Sigo como réplica")
            self.demote("etcd sin mayoría")
            return
        self.quiet.discard("noquorum")
        if kv:
            self.absent_since = 0.0
            self.quiet -= {"stale", "stale-grace", "nohb", "reserved"}
            name = kv["value"].get("node", "")
            if name != self.last_leader:
                self.say(f"Primario actual: {name}, época {kv['create_revision']}")
                self.last_leader = name
                self.write_leader(name)
            self.demote(f"{name} es el primario")
            return
        if time.time() < self.cooldown_until or os.path.exists(self.path("hold")):
            return
        try:
            res = self.etcd.get(RESERVE_KEY)
        except EtcdError:
            return
        reserved_for = res["value"].get("node") if res else None
        if reserved_for and reserved_for != self.me:
            self.once("reserved", f"El puesto está reservado para {reserved_for}")
            return
        rank = self.servers.index(self.me) if self.me in self.servers else len(self.servers)
        if not self.absent_since:
            self.absent_since = time.time()
        if reserved_for != self.me and not self.fresh(rank):
            return
        # El último primario va primero, así un corte breve de etcd no cambia de primario.
        # Después sigue el orden de SERVERS.
        last = self.last_primary()
        order = ([last] if last in self.servers else []) + [s for s in self.servers if s != last]
        pos = order.index(self.me) if self.me in order else len(order)
        if not reserved_for and pos > 0:
            self.say(f"No hay primario. Espero {pos * self.rank_delay:.0f} s por los {pos} servidores que van antes")
            time.sleep(pos * self.rank_delay)
            try:
                if self.etcd.get(KEY):
                    return
            except EtcdError:
                return
        try:
            lease = self.etcd.grant(self.ttl)
            ok, rev = self.etcd.create(KEY, {"node": self.me, "since": time.time()}, lease)
        except EtcdError as exc:
            self.say(f"No pude postularme: {exc}")
            return
        if not ok:
            try:
                self.etcd.revoke(lease)
            except EtcdError:
                pass
            return
        self.leader, self.lease, self.last_ok = True, lease, time.time()
        self.quiet.clear()
        self.promote(rev)
        if reserved_for == self.me:
            try:
                self.etcd.delete(RESERVE_KEY)
            except EtcdError:
                pass

    def last_primary(self) -> str:
        try:
            last = self.etcd.get(LAST_KEY)
        except EtcdError:
            return ""
        return last["value"].get("node", "") if last else ""

    def heartbeat(self) -> dict | None:
        try:
            return json.load(open(os.path.join(self.export_dir, ".cluster", "heartbeat"), encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def fresh(self, rank: int) -> bool:
        """¿Tengo los datos del último primario? Evita que asuma un servidor que estuvo caído."""
        try:
            last = self.etcd.get(LAST_KEY)
        except EtcdError:
            return False
        hb = self.heartbeat()
        if not last:
            if rank > 0 and hb is None:
                self.once("nohb", "Nunca recibí réplica, no me postulo")
                return False
            return True
        info = last["value"]
        if info.get("node") == self.me:
            return True
        if hb and str(hb.get("epoch")) == str(info.get("epoch")):
            return True
        waited = time.time() - self.absent_since
        if waited > self.stale_grace:
            self.once("stale-grace", f"Nadie con datos al día asumió en {self.stale_grace:.0f} s. Me postulo con lo que tengo")
            return True
        self.once("stale", f"Mis datos no son del último primario ({info.get('node')}, época {info.get('epoch')}). Dejo que asuma otro")
        return False

    def run(self, max_ticks: int | None = None) -> None:
        self.say(f"Elector de {self.me}. Sucesión {' '.join(self.servers)}, contrato de {self.ttl} s, etcd {','.join(self.etcd.endpoints)}")
        if os.path.exists(self.path("primary")):
            # Arranca después de una caída con el archivo de primario. Nunca se arranca como
            # primario sin ganar la elección.
            self.leader = False
            self.demote("arranque, primero hay que ganar la elección")
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while max_ticks is None or self.ticks < max_ticks:
            self.tick()
            time.sleep(1)


def cmd_status(conf: dict, as_json: bool) -> int:
    etcd = Etcd(endpoints_from(conf))
    out: dict = {"endpoints": etcd.endpoints}
    try:
        kv = etcd.get(KEY)
        res = etcd.get(RESERVE_KEY)
        out["primary"] = kv["value"].get("node") if kv else None
        out["epoch"] = kv["create_revision"] if kv else None
        out["reserved_for"] = res["value"].get("node") if res else None
        out["members"] = [m.get("name") for m in etcd.members()]
        out["raft_leader"] = etcd.raft_leader()
        out["quorum"] = True
    except EtcdError as exc:
        out["quorum"] = False
        out["error"] = str(exc)
    if as_json:
        print(json.dumps(out))
    elif out["quorum"]:
        print(f"Primario        {out['primary'] or 'ninguno'}  época {out['epoch'] or '-'}")
        print(f"etcd            {len(out['members'])} miembros: {', '.join(out['members'])}. Líder de Raft: {out['raft_leader']}")
        if out["reserved_for"]:
            print(f"Reserva         {out['reserved_for']}")
    else:
        print(f"etcd sin mayoría: {out['error']}")
    return 0 if out["quorum"] else 1


def main(argv: list[str]) -> int:
    conf = load_conf()
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "run":
        Elector(conf).run()
        return 0
    if cmd == "status":
        return cmd_status(conf, "--json" in argv)
    if cmd == "leader":
        try:
            kv = Etcd(endpoints_from(conf)).get(KEY)
        except EtcdError:
            return 1
        if not kv:
            return 1
        print(kv["value"].get("node", ""))
        return 0
    if cmd == "reserve" and len(argv) == 4:
        etcd = Etcd(endpoints_from(conf))
        etcd.put(RESERVE_KEY, {"node": argv[2]}, etcd.grant(int(argv[3])))
        return 0
    if cmd == "unreserve":
        Etcd(endpoints_from(conf)).delete(RESERVE_KEY)
        return 0
    if cmd == "stepdown":
        state = conf.get("STATE_DIR", "/var/lib/sad-lab")
        if not os.path.exists(os.path.join(state, "primary")):
            return 0
        open(os.path.join(state, "stepdown"), "w").close()
        for _ in range(30):
            if not os.path.exists(os.path.join(state, "primary")):
                return 0
            time.sleep(0.5)
        return 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

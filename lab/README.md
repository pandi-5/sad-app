# Laboratorio: sistema de archivos distribuido con réplica

Grupo 4, Sistemas de archivos distribuidos. Cuatro equipos Windows con WSL y
Tailscale.

```
  Cliente 1 ─┐                         ┌─ Servidor A (primario, rw)
             ├── red Tailscale (NFS) ──┤        │ rsync cada 2 s
  Cliente 2 ─┘                         └─ Servidor B (réplica, ro)
```

| Equipo | Rol | Scripts |
| --- | --- | --- |
| Integrante 1 | Servidor A | 00, 01 primario, 03 |
| Integrante 2 | Servidor B | 00, 01 replica, 04 si A cae |
| Integrante 3 | Cliente 1 | 00, 02 |
| Integrante 4 | Cliente 2 | 00, 02 |

## Preparación (todos)

1. Instalen Tailscale en cada equipo con la misma cuenta, o inviten a los demás
   a la red de uno de ustedes.
2. En WSL: `git clone https://github.com/pandi-5/sad-app` y `cd sad-app/lab`.
3. `./00-wsl-tailscale.sh`. Si pide reiniciar WSL, hagan `wsl --shutdown`
   en PowerShell y ejecútenlo otra vez.
4. Anoten la IP de Tailscale de cada equipo con `tailscale ip -4`.
5. Edite `lab.env` en cada equipo: `SERVIDOR_A`, `SERVIDOR_B` y `USUARIO`
   (el usuario de WSL de los servidores).

## Servidores

- En A: `./01-servidor.sh primario`
- En B: `./01-servidor.sh replica`
- En A, una sola vez: `ssh-keygen` y `ssh-copy-id USUARIO@IP_DE_B`
- En A: `./03-replicar.sh` y dejarlo abierto.

Si `01-servidor.sh` dice que falta `nfsd`, prueben `wsl --update` y reinicien
WSL. Si sigue igual, vean el Plan B.

## Clientes

`./02-cliente.sh a` en ambos. Comprueben con `ls /mnt/compartido`.

## Guion de la demo

1. **Acceso compartido.** El cliente 1 crea `echo hola > /mnt/compartido/doc.txt`
   y el cliente 2 lo lee con `cat`.
2. **Operaciones.** Crear, leer, renombrar y borrar desde un cliente y verlo en
   el otro.
3. **Concurrencia sin protección.** Ejecuten a la vez `demo/editar.sh Cliente1`
   y `demo/editar.sh Cliente2`. Los dos leen 0 y escriben 1, así que se pierde
   una actualización.
4. **Concurrencia con bloqueo.** Repitan con `--lock`. El segundo espera y el
   resultado final es 2. El bloqueo es consultivo, solo funciona si todos lo usan.
5. **Retraso de la réplica.** En A: `demo/medir-replica.sh`. Muestra los segundos
   que tarda un archivo en llegar a B, que es consistencia eventual.
6. **Caída de A.** Apaguen WSL en A con `wsl --shutdown`. En un cliente, `ls` falla o
   tarda unos segundos. En B ejecuten `./04-promover.sh` y en los clientes
   `./02-cliente.sh b`. Los documentos siguen disponibles.
7. **Límites.** Lo que se escribió en A en los últimos segundos antes de la caída
   puede no estar en B, y la conmutación es manual.

## sad-app sobre esta infraestructura

`sad-app` resuelve la concurrencia en la capa de aplicación con los modos
`libre`, `versiones` y `bloqueo`. Para replicarla, en A ejecuten
`./05-replicar-sad.sh /ruta/a/sad-app`. La ruta debe ser la misma en B. En una
caída, arranquen `python run.py` en B.

## Plan B si NFS no funciona en WSL

SSHFS no necesita módulos del kernel. En el servidor: `sudo apt install openssh-server`.
En el cliente: `sudo apt install sshfs` y
`sshfs USUARIO@IP_DE_A:/srv/compartido /mnt/compartido -o reconnect`.
Conceptualmente es lo mismo, pero explíquenlo como alternativa a NFS.

## Preguntas que conviene saber responder

- ¿Por qué NFS no evita que dos clientes se pisen? Porque garantiza consistencia
  al cerrar y abrir el archivo, no transacciones.
- ¿Qué pasa con la réplica si A cae a mitad de una copia? B queda con datos
  desactualizados o incompletos de ese último ciclo.
- ¿Cómo se haría de verdad? Con un sistema replicado como GlusterFS o Ceph, que
  replica de forma síncrona y conmuta solo.

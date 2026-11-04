# cyremia-init

Mise en service d'une machine Ubuntu (Server ou Desktop) fraîchement installée,
pour l'intégrer au parc Cyremia.

```bash
curl -fsSL init.cyremia.cloud | sudo bash
```

Le script pose, dans l'ordre et de façon idempotente :

1. le nom de la machine (convention `cyr-<pc|srv|rpi>-<rôle>-<NN>`) ;
2. les outils de base (`curl`, `ufw`, `smartmontools`, `htop`, `jq`, `openssh-server`) ;
3. les clés SSH publiques Cyremia, `sudo` sans mot de passe, SSH **par clé uniquement** ;
4. les mises à jour de sécurité automatiques, **sans redémarrage automatique** ;
5. Tailscale (clé d'authentification ou lien de connexion) ;
6. l'agent Beszel (métriques, port 45876) ;
7. l'agent Alloy (journald → Loki, via Tailscale) ;
8. le pare-feu `ufw` : tout fermé sauf `22/tcp` et `tailscale0` ;
9. un bilan SMART des disques.

Variables facultatives : `NOM=cyr-pc-atelier-01`, `TS_AUTHKEY=tskey-auth-…`

```bash
curl -fsSL init.cyremia.cloud | sudo NOM=cyr-pc-atelier-01 bash
```

Restent à faire à la main : ajouter la machine dans Beszel, installer l'agent NinjaOne.

Ce dépôt est **public** : il ne doit contenir aucun secret.

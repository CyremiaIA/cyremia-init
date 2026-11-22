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

Variables facultatives : `NOM=cyr-pc-atelier-01`, `TS_AUTHKEY=tskey-auth-…`,
`LOKI_PUSH_PASSWORD=…`

```bash
curl -fsSL init.cyremia.cloud | sudo NOM=cyr-pc-atelier-01 bash
```

### Mot de passe d'envoi Loki (agent Alloy)

Depuis le 2026-11-23, Loki est derrière un proxy qui refuse tout envoi sans
l'identifiant `agent` (voir le README de `cyremia-logs`, « Accès et identifiants »).
Le mot de passe vit dans la variable Coolify `LOKI_PUSH_PASSWORD` et, sur le Mac
d'Aymeric, dans `~/.config/cyremia/loki-envoi`. Le script l'obtient dans cet ordre :

1. variable d'environnement `LOKI_PUSH_PASSWORD` ;
2. installation précédente (`/etc/default/alloy`), quand on relance le script ;
3. question au clavier en début de script, **saisie masquée** (rien ne s'affiche).

Il vérifie ensuite l'identifiant auprès du proxy (envoi d'un lot vide). Mot de passe
absent ou refusé : **Alloy n'est pas installé**, un avertissement le dit et le script
se termine en code 2, plutôt que d'installer un agent dont tous les envois partiraient
en 401 sans bruit. Le mot de passe n'est jamais affiché ni écrit dans
`/var/log/cyremia-init.log` ; il est stocké dans `/etc/default/alloy` (`0640 root:alloy`).

Éviter de le taper sur la ligne de commande (il resterait dans l'historique du shell) :
préférer la question au clavier.

Restent à faire à la main : ajouter la machine dans Beszel, installer l'agent NinjaOne.

Ce dépôt est **public** : il ne doit contenir aucun secret.

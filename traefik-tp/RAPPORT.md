# TP5 — Reverse Proxy et Load Balancing avec Traefik et Docker

Environnement : Windows 11, Docker Desktop (Engine 29.1.3, Compose v2.40.3), curl 8.12.1. Testé le 06/11/2026.

## 1. Arborescence livrée

```
traefik-tp/
├── docker-compose.yml          # Traefik + app1 + app1b + app2 + app3-private (témoin)
├── config/
│   ├── traefik.yaml            # configuration statique
│   └── dynamic/tls.yaml        # configuration dynamique fichier : certificat, TLS ≥ 1.2, middlewares
├── app1/ app1b/ app2/ app3/    # pages HTML uniquement (aucun secret)
├── scripts/gen-certs.sh        # CA locale + certificat app1/app2.localhost
├── certs/                      # généré, exclu de Git (.gitignore)
├── exercice5/                  # architecture cible proposée (compose + statique + middlewares)
└── .gitignore
```

Lancement :

```bash
docker network create frontend
bash scripts/gen-certs.sh
docker compose up -d
```

## 2. Écarts par rapport à l'énoncé

| Écart | Raison |
|---|---|
| `traefik:v3.6.2` au lieu de `v3.5.2` | Avec v3.5.2, le provider Docker échoue en boucle (`API returned a 400 (Bad Request)`, constaté dans `docker logs traefik-1`) : Docker Engine 29 exige au minimum l'API 1.44 et Traefik v3.5.2 négocie une version plus ancienne. On reste sur une version précise, sans tag flottant. |
| `nginx:1.28.0` au lieu de `nginx:stable` | Le TP demande d'identifier précisément les versions déployées. |
| Nginx durci (`read_only`, `tmpfs`, `cap_drop: ALL`, `no-new-privileges`) | Section « Appliquer le moindre privilège ». Vérifié : `ReadonlyRootfs=true CapDrop=[ALL] SecOpt=[no-new-privileges:true]`, et les workers tournent sous un utilisateur non root. |
| Provider `file` ajouté | Nécessaire pour fournir le certificat TLS et les middlewares (phases 7 et 8) sans mettre de secret dans les labels. |
| Health check sur le service `app1` | Pour la politique de santé (exercice 5, question 12). |
| Conteneur `app3-private` sans `traefik.enable=true` | Sert de témoin pour le critère « aucune route sans autorisation explicite ». |

## 3. Preuves de fonctionnement (exercices 1 à 3)

**Ports exposés** (`docker ps`) :

```
traefik-1     0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, 127.0.0.1:8080->8080/tcp
nginx-app1    80/tcp        <- port interne seulement, rien de publié sur l'hôte
nginx-app1b   80/tcp
nginx-app2    80/tcp
nginx-app3-private 80/tcp
```

**Routage par nom d'hôte :**

```
$ curl http://app1.localhost                         -> <h1>App1 - Bonjour depuis App1</h1>
$ curl http://app2.localhost                         -> <h1>App2 - Bonjour depuis App2</h1>
$ curl -H "Host: app2.localhost" http://localhost    -> <h1>App2 - Bonjour depuis App2</h1>
```

**Routers et services vus par l'API** (`/api/http/routers` et `/api/http/services`) :

```
app1@docker         Host(`app1.localhost`)  [web]        -> app1  enabled
app1-secure@docker  Host(`app1.localhost`)  [websecure]  -> app1  enabled  tls  [security-headers@file]
app2@docker         Host(`app2.localhost`)  [web]        -> app2  enabled
app1@docker  {'http://172.23.0.3:80': 'UP', 'http://172.23.0.5:80': 'UP'}   <- 2 backends
app2@docker  {'http://172.23.0.2:80': 'UP'}
```

**Load Balancing** (round-robin pondéré, alternance stricte) :

```
$ for i in $(seq 1 6); do curl -s http://app1.localhost; done
<h1>Bonjour depuis App1 - Instance B</h1>
<h1>App1 - Bonjour depuis App1</h1>
<h1>Bonjour depuis App1 - Instance B</h1>
<h1>App1 - Bonjour depuis App1</h1>
...
```

**Disponibilité** : après `docker stop nginx-app1b`, 4 requêtes sur 4 renvoient `200`, et le service ne compte plus qu'un seul backend `UP`. Après `docker start`, les deux backends repassent `UP` et l'alternance reprend.

## 4. Critères d'acceptation de sécurité, avec leur preuve

| Critère | Test | Résultat |
|---|---|---|
| Aucun port Nginx publié | `docker ps`, `docker port nginx-app1`, `curl localhost:8081` | aucun port publié ; connexion refusée |
| Pas de route sans `traefik.enable=true` | `curl http://app3.localhost` ; recherche de `app3` dans `/api/http/routers` | `404` ; 0 occurrence (le label `routers.app3.rule` est ignoré) |
| Hôte inconnu | `curl -H "Host: inconnu.localhost" http://localhost` | `404` |
| Dashboard et API inaccessibles depuis une machine non autorisée | `curl http://10.60.104.162:8080/api/overview` (IP Wi-Fi) | connexion refusée. En local : `200` |
| Pas de secret dans les labels ni dans Git | revue de `docker-compose.yml` ; `.gitignore` couvre `certs/`, `*.key`, `.env`, `*.htpasswd` | OK |
| HTTPS vérifié **sans `-k`** | `curl --cacert certs/ca.crt https://app1.localhost` (curl OpenSSL en conteneur) | page servie, chaîne et nom vérifiés |
| Refus d'une CA non approuvée | même requête sans `--cacert` | `curl: (60) unable to get local issuer certificate` |
| Nom non couvert par le certificat | `https://evil.localhost` (`sniStrict`) | `tlsv1 unrecognized name` |
| TLS < 1.2 refusé | `curl --tls-max 1.1 ...` | échec de négociation (code 35) |
| En-têtes de sécurité sur la route HTTPS | `curl -I` | `Strict-Transport-Security`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` |

Remarque sur Windows : le curl natif (Schannel) refuse la CA locale avec `CERT_TRUST_REVOCATION_STATUS_UNKNOWN`, car la CA de labo ne publie pas de CRL. `curl --cacert certs/ca.crt --ssl-no-revoke` fonctionne : cette option ne désactive que la vérification de révocation, la chaîne et le nom restent vérifiés (rien à voir avec `-k`).

### Limites constatées (le 404 ne prouve pas tout)

1. **Depuis les conteneurs, l'API reste joignable.** Un conteneur du réseau `frontend` obtient `200` sur `http://traefik-1:8080/api/overview`, et un conteneur quelconque l'obtient aussi via `host.docker.internal:8080`. La liaison `127.0.0.1` ne protège que contre les autres machines. Une application compromise pourrait donc lire toute la topologie. Correctif en production : `api.insecure: false` et un router `api@internal` sur un entrypoint dédié, avec allowlist et authentification (voir exercice 5).
2. Le réseau `frontend` est partagé : app1 peut joindre app2 et app3 directement, sans passer par Traefik.
3. Les applications restent joignables sur le port 80 depuis le réseau local (IP Wi-Fi). C'est normal pour un entrypoint public, mais cela veut dire qu'on ne doit faire passer que des données fictives en HTTP.

## 5. Exercice 1 — Entrypoint et router

L'**entrypoint** est une porte réseau (adresse et port, ici `:80` et `:443`) : il décide *où Traefik écoute*. Le **router** est une règle appliquée aux requêtes qui arrivent sur un ou plusieurs entrypoints (`Host(...)`, `PathPrefix(...)`, etc.) : il décide *à quel service envoyer* la requête, et avec quels middlewares et quel TLS. Un même entrypoint porte plusieurs routers : ici `web` porte `app1` et `app2`.

## 6. Exercice 2 — Pourquoi un seul port suffit pour deux applications

Les deux requêtes arrivent sur l'entrypoint `web:80`. Traefik compare l'en-tête `Host` aux règles des routers : `app1.localhost` correspond au router `app1`, qui envoie vers le service `app1`, et `app2.localhost` correspond au router `app2`, qui envoie vers le service `app2`.

## 7. Exercice 3 — Load Balancing et routage

Le routage choisit **l'application** à partir de la requête (Host, chemin). Le Load Balancing choisit **l'instance** parmi les backends d'un même service. app1 et app1b déclarent le même router et le même service (ancre YAML `*app1-labels`, donc des labels identiques par construction). Traefik les fusionne en un service `app1` à deux serveurs et alterne les réponses (WRR). Le client ne voit qu'un seul nom : `app1.localhost`.

## 8. Exercice 4 — Sécurité

1. **`api.insecure: true`** publie l'API et le dashboard sur l'entrypoint `traefik:8080`, **sans authentification ni TLS**. Ils exposent tous les routers, règles, services, IP internes et middlewares, ce qui fait une carte complète pour un attaquant. Si le port est publié sur `0.0.0.0`, n'importe qui sur le réseau y a accès. Et comme constaté plus haut, les conteneurs y ont accès même avec la liaison `127.0.0.1`.
2. **Le socket Docker** donne accès à l'API complète du démon, qui tourne en root. Le `:ro` ne porte que sur le fichier : les appels `POST /containers/create` ou `exec` restent possibles. Quiconque contrôle Traefik (par une faille ou une mauvaise configuration) peut lancer un conteneur `--privileged` qui monte `/` de l'hôte, et donc prendre le contrôle de l'hôte entier.
3. **Protéger le dashboard** : `api.insecure: false` ; router `api@internal` sur un entrypoint `admin` publié uniquement sur l'interface VPN ou admin ; middlewares `ipAllowList` et `basicAuth` (avec `usersFile`, hash bcrypt, fichier hors Git) ou ForwardAuth/SSO ; TLS obligatoire ; Traefik séparé des applications réseau par réseau ; accès journalisés.
4. **`traefik.enable=true` plutôt que l'exposition par défaut** : avec `exposedByDefault: true`, tout conteneur rattaché au réseau (base de données, outil interne, conteneur de debug) recevrait automatiquement une route `<service>.<projet>`. L'opt-in rend chaque exposition explicite, relisable et traçable. Le témoin `app3-private` le prouve : il n'obtient aucune route malgré un label `rule`.
5. **TLS activé ou certificat valide** : `tls=true` chiffre la connexion, mais sans certificat fourni Traefik présente son certificat auto-signé par défaut (`TRAEFIK DEFAULT CERT`). Le canal est chiffré, mais l'identité du serveur n'est pas prouvée, donc une attaque de l'homme du milieu reste possible. Un certificat **valide** correspond au nom demandé, n'est pas expiré et chaîne jusqu'à une CA à laquelle le client fait confiance. C'est ce que vérifie `curl` sans `-k`.

## 9. Exercice 5 — Architecture cible

Fichiers : [exercice5/docker-compose.yml](exercice5/docker-compose.yml), [exercice5/traefik.yaml](exercice5/traefik.yaml), [exercice5/dynamic/middlewares.yaml](exercice5/dynamic/middlewares.yaml). La syntaxe est validée par `docker compose config`. Cette architecture n'a pas été déployée, car elle exige un vrai domaine pour ACME et un VPN.

```
                Internet                                   VPN admin (10.8.0.0/24)
                   │ 80 / 443                                        │ 8443
                   ▼                                                  ▼
   ┌───────────────────────────────── Traefik v3.6.2 ─────────────────────────────┐
   │ web:80 ──redirect──▶ websecure:443 (Let's Encrypt, TLS ≥1.2, HSTS)            │
   │ admin:8443 ── vpn-only + admin-auth ──▶ api@internal (dashboard)              │
   └───────┬──────────────────────┬──────────────────────┬──────────────┬─────────┘
           │ front-public          │ front-public          │ front-private│ socket (internal)
           ▼                       ▼                       ▼              ▼
   shop.devtech.example     blog.devtech.example   admin.devtech.example  docker-socket-proxy
   router shop              router blog            router admin            (GET only, POST=0)
   [headers, rate-limit]    [headers]              [basicAuth, headers]        │
   service shop (WRR)       service blog           service admin               ▼
     ├─ shop-a ◀─ healthcheck /healthz 5s                                 docker.sock
     └─ shop-b
```

Points clés :

* **3 applications** : shop, blog, admin. **2 instances** pour shop, avec le même router et le même service, plus un health check : une instance malade est retirée de la rotation.
* **HTTPS** : resolver ACME `le` (`tlsChallenge`), redirection globale sur l'entrypoint `web`, stockage `acme.json` dans un volume dédié.
* **Authentification** : middleware `admin-auth@file` (`basicAuth.usersFile`). Le hash n'apparaît dans aucun label.
* **Dashboard non public** : `insecure: false`, entrypoint `admin` publié uniquement sur `10.8.0.1`, `ipAllowList` et BasicAuth.
* **Socket Docker** : Traefik ne le monte plus. Il interroge `docker-socket-proxy` en lecture seule, sur un réseau `internal`.
* **Segmentation** : `admin` est sur `front-private`, isolé de shop et blog. Les réseaux applicatifs sont `internal`, donc sans sortie.
* **Disponibilité** : deux instances sur un seul hôte ne protègent pas d'une panne de l'hôte. Pour une vraie haute disponibilité, il faut plusieurs nœuds (Swarm ou Kubernetes), au moins deux Traefik derrière une IP flottante ou un LB externe, et des sauvegardes de la configuration et d'`acme.json`.

Labels de la route HTTPS principale :

```yaml
- "traefik.enable=true"
- "traefik.http.routers.shop.rule=Host(`shop.devtech.example`)"
- "traefik.http.routers.shop.entrypoints=websecure"
- "traefik.http.routers.shop.tls.certresolver=le"
- "traefik.http.routers.shop.middlewares=security-headers@file,rate-limit@file"
- "traefik.http.services.shop.loadbalancer.server.port=80"
- "traefik.http.services.shop.loadbalancer.healthcheck.path=/healthz"
- "traefik.http.services.shop.loadbalancer.healthcheck.interval=5s"
```

## 10. Questions de compréhension

1. **Reverse proxy** : serveur placé devant les applications. Il reçoit les requêtes des clients et les transmet au bon backend. Le client ne connaît que le proxy, jamais les adresses internes. À l'inverse, un forward proxy agit pour le compte des *clients* qui sortent vers Internet.
2. **Reverse proxy ou Load Balancer** : le reverse proxy *choisit l'application* (routage, TLS, middlewares). Le load balancer *répartit la charge* entre plusieurs instances équivalentes. Traefik fait les deux.
3. **Rôle de Traefik dans Docker** : point d'entrée unique (80/443). Il découvre les conteneurs via l'API Docker, construit les routes à partir des labels, termine TLS, applique les middlewares et répartit la charge.
4. **Statique ou dynamique** : la configuration statique (entrypoints, providers, API, logs, resolvers) est lue au démarrage et demande un redémarrage. La configuration dynamique (routers, services, middlewares, TLS) est rechargée à chaud depuis les providers.
5. **Provider** : source de configuration dynamique (Docker, Kubernetes, fichier, etc.). Traefik l'écoute en continu.
6. **Entrypoint** : socket d'écoute réseau (port, protocole) par lequel entrent les requêtes.
7. **Router ou service** : le router *décide* (règle, entrypoints, TLS, middlewares). Le service *exécute* : il désigne les serveurs backend et la façon d'équilibrer la charge entre eux.
8. **Labels Docker** : ils permettent de déclarer la configuration dynamique au plus près du conteneur, versionnée avec lui, sans toucher Traefik.
9. **`exposedByDefault: false`** : aucun conteneur n'est routé sans opt-in `traefik.enable=true`. On évite ainsi l'exposition accidentelle d'une base de données ou d'un outil interne.
10. **Découverte automatique** : Traefik s'abonne aux *events* de l'API Docker (start, stop, die). À chaque événement, il relit les conteneurs et leurs labels, puis reconstruit les routes.
11. **Routage ou Load Balancing** : le routage sélectionne l'application (Host, chemin). Le Load Balancing sélectionne une instance parmi celles du service choisi.
12. **Santé des backends** : sans health check, Traefik continue d'envoyer du trafic vers une instance qui répond mal (502, timeouts). Avec un health check, elle est retirée de la rotation puis réintégrée quand elle va mieux.
13. **Protéger le dashboard** : il révèle toute la topologie (routes, IP internes, middlewares). Sans authentification, c'est une reconnaissance gratuite pour un attaquant.
14. **Router TLS sans certificat valide** : `tls=true` active le chiffrement, mais Traefik sert son certificat par défaut auto-signé tant qu'aucun certificat ou resolver correspondant au nom n'est fourni. Le client ne peut pas authentifier le serveur.
15. **Nouvelle instance sans changer le point d'entrée** : on lance un conteneur avec les **mêmes** noms de router et de service (ou `docker compose up --scale app1=3`). Traefik l'ajoute au service, et le client garde la même URL.
16. **`Host(...)` n'est pas une authentification** : l'en-tête `Host` est entièrement contrôlé par le client (`curl -H "Host: ..."`). Il sert à choisir une application, pas à prouver une identité.
17. **`docker.sock:ro`** : le `ro` protège le *fichier* socket, pas l'API derrière lui. Les requêtes HTTP `POST` (créer un conteneur, `exec`) passent quand même, ce qui revient à un accès root sur l'hôte.
18. **Protéger l'API autant que le dashboard** : le dashboard n'est qu'une interface au-dessus de l'API `/api/*`, qui renvoie les mêmes informations en JSON, faciles à exploiter par un script.
19. **Réseau partagé ou segmentation** : sur un réseau partagé, tous les conteneurs se joignent directement, ce qui permet un mouvement latéral. Avec la segmentation, un réseau est créé par niveau de confiance, et seul Traefik est rattaché à plusieurs réseaux.
20. **Deux instances sur un même hôte** : elles partagent l'hôte, le démon Docker, le disque, le réseau et le Traefik unique. Une panne de l'un d'eux arrête tout. La haute disponibilité suppose des domaines de panne distincts.
21. **Preuves qu'un contrôle fonctionne** : des tests *négatifs* reproductibles (accès refusé depuis une machine non autorisée, refus sans `--cacert`, 404 et absence dans l'API pour un conteneur non autorisé), l'inspection de la configuration effective (`docker ps`, `docker inspect`, `/api/http/routers`), des journaux d'accès, et des tests de panne (arrêt d'une instance). Une seule réponse positive ou un seul 404 ne suffit pas.

## 11. Cartographie de sécurité — état dans le labo

| Composant / flux | Priorité | Mise en œuvre dans le labo | Preuve |
|---|---|---|---|
| Clients → Traefik 80/443 | P1 | HTTPS avec CA locale, TLS ≥ 1.2, `sniStrict`, en-têtes de sécurité ; HTTP conservé pour le TP | curl sans `-k`, refus TLS 1.1 et nom inconnu |
| Admins → dashboard/API | P1 | **Partiel** : `127.0.0.1:8080`, mais joignable depuis les conteneurs | refus depuis l'IP Wi-Fi, `200` depuis `frontend` (limite) |
| Traefik → API Docker | P1 | **Non traité dans le labo** (socket monté) ; socket-proxy dans l'exercice 5 | `docker inspect traefik-1` |
| Traefik → App1/App1B | P1 | aucun port publié, health check, durcissement Nginx | test d'arrêt d'app1b |
| Traefik → App2/App3 | P1 | opt-in par label ; **réseau partagé** (segmentation dans l'exercice 5) | app3 absente de l'API |
| Configurations et labels | P1 | aucun secret dans les labels, `.gitignore` | revue des fichiers |
| Certificats et secrets | P1 | `certs/` hors Git, `chmod 600` sur les clés, validité de 30 jours | `ls certs`, `.gitignore` |
| Images et conteneurs | P1 | versions fixées, `no-new-privileges`, `cap_drop`, rootfs en lecture seule | `docker inspect` |
| Journaux et supervision | P2 | `accessLog` activé, `DEBUG` à remplacer par `INFO` hors labo | `docker logs traefik-1` |
| Hôte Docker / Traefik | — | instance unique, non redondée | — |

## 12. Nettoyage

```bash
docker compose down
docker network rm frontend
```

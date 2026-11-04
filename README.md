<p align="center">
  <img src="./docs/image/gvoxel-logo.png" alt="Logo GVoxel" width="760">
</p>

# GVoxel

**Creusez les murs, transformez le terrain et ouvrez de nouveaux passages dans vos maps Garry’s Mod.**

GVoxel est un addon Lua qui analyse une portion de la géométrie BSP d’une map et la reconstruit sous forme de terrain voxel modifiable. Les textures de la map sont reprises, de nouvelles collisions sont préparées et les trous deviennent des passages utilisables par les joueurs, les objets et les systèmes compatibles.

**Une seule zone persistante par map · Outils réservés aux administrateurs · Intégrations véhicules et explosifs · Multijoueur en cours de validation**

## Comment ça fonctionne ?

1. Un administrateur délimite une zone avec une cage standard ou une boîte personnalisée.
2. GVoxel analyse les surfaces, les matériaux et le relief présents dans cette zone.
3. Un maillage destructible et ses collisions prennent le relais à l’intérieur de la sélection. Le BSP d’origine reste présent dans le fichier de la map.
4. Chaque creusement ou ajout de matière reconstruit les parties concernées, sans relancer l’analyse complète.
5. La zone et ses modifications sont sauvegardées pour les prochaines parties sur cette map.

L’objectif est de conserver l’aspect de l’environnement tout en permettant de traverser réellement les ouvertures créées. À la sortie de la zone, les collisions classiques de la map reprennent le relais.

## Terrain, textures et éclairage

- Analyse des murs, bâtiments, sols BSP et terrains Hammer de type **displacement**.
- Prise en compte des pentes, des sols superposés et des surfaces ouvertes ou constituées d’une seule face.
- Retrait et ajout de matière dans les limites de la zone analysée.
- Reprise des matériaux, de l’échelle et de l’orientation des textures d’origine.
- Capture de l’apparence des surfaces existantes, avec une résolution adaptée aux budgets de rendu.
- Éclairage des nouvelles parois à partir d’informations de l’environnement et des surfaces voisines.
- Prise en charge des lumières dynamiques, lampes et lampes torches.
- Gestion de la vue à travers les ouvertures : environnement extérieur, skybox et entités visibles, avec contrôle de l’occlusion.

L’éclairage des surfaces nouvellement révélées reste une approximation : GVoxel ne recalcule pas les lightmaps compilées de la map. Les angles complexes, reflets et zones optimisées par le moteur Source peuvent encore demander des ajustements.

## Joueurs, objets et IA

Les adaptations de collision et de traces permettent aux éléments compatibles d’utiliser le nouveau terrain :

- **Joueurs** : déplacement et collisions dans les excavations.
- **Props et ragdolls** : interaction avec le sol voxel et les trous.
- **Physics Gun et Gravity Gun** : manipulation d’objets à travers les ouvertures.
- **Lumières et lampes de GMod** : intégration physique et éclairage du terrain.
- **PNJ terrestres et NextBots compatibles** : adaptation locale du déplacement et recherche de passages sur le terrain voxel.
- **Balles et projectiles compatibles** : traversée des trous déjà ouverts, en conservant les obstacles encore présents.

Le passage des projectiles et la destruction sont deux fonctions distinctes : une balle ordinaire peut traverser une ouverture sans creuser elle-même le mur. La navigation des PNJ s’appuie sur une adaptation locale ; elle ne remplace pas intégralement les réseaux de navigation de la map ni les IA propres à chaque addon.

## Véhicules

GVoxel inclut des adaptations pour plusieurs familles de véhicules :

| Système | Intégration prévue |
| --- | --- |
| **Véhicules natifs HL2 / GMod** | Jeep, Jalopy et adaptation des contacts de roues avec le terrain voxel. |
| **Glide** | Châssis, roues et assemblages associés ; intégration de certains projectiles et explosifs. |
| **LVS** | Adaptation des véhicules et de leurs éléments physiques associés. |
| **Simfphys** | Adaptation des véhicules et roues physiques associées. |

Ces intégrations visent à permettre de rouler sur les voxels, de tomber dans une excavation et de franchir un mur détruit lorsque l’ouverture est assez large. Elles tiennent aussi compte du rendu des roues et de la conservation de l’apparence du véhicule.

La compatibilité est organisée par système de véhicules, plutôt que par modèle individuel. Elle ne garantit toutefois pas le fonctionnement de chaque véhicule personnalisé : dimensions, contraintes physiques, suspension et contrôleurs propres aux addons peuvent nécessiter des essais supplémentaires. L’Airboat conserve son contrôleur natif, distinct du support des véhicules à roues.

## Explosions et armes

Les destructions explosives utilisent un traitement commun, avec une taille de trou adaptée aux informations disponibles sur l’explosion.

- **RPG de base de Garry’s Mod**.
- **Grenades explosives HL2**.
- **SLAM HL2**, charges et mines à déclenchement par faisceau.
- **Char Glide** : les impacts reconnus peuvent creuser une ouverture dimensionnée selon le gabarit du char pour faciliter son passage.
- **Avions Glide P-996 Lazer et B-11 Strikeforce** : intégration des missiles reconnus, guidés ou non guidés.
- **Armes explosives d’autres addons** lorsqu’elles émettent les événements de dégâts explosifs pris en charge.

La destruction reste limitée à la zone voxel. Un mur épais, une cage trop petite ou un projectile utilisant un système entièrement spécifique peuvent limiter le résultat. Une explosion uniquement visuelle, sans événement exploitable, ne peut pas être détectée automatiquement.

## Zone persistante et administration

GVoxel conserve **une seule zone active et sauvegardée par map**.

- Cages standard de **16 ou 32 mètres**.
- Mode **Custom block** : boîte alignée sur les axes de la map, définie en quatre points.
- Aperçu des limites et dimensions avant l’analyse.
- Sauvegarde automatique après l’analyse, puis après les modifications validées.
- Restauration automatique au lancement d’une nouvelle partie sur la même map.
- Gestion depuis **Utilities → GVoxel → Zones persistantes** : sauvegarde, nom, réactivation, retrait de la zone et suppression du cache.
- Création, modification et outils de gestion réservés aux **administrateurs**.

Le cache évite de refaire l’intégralité des relevés de terrain. Les maillages, captures visuelles et objets physiques doivent néanmoins être préparés au chargement. Les caches incompatibles avec la map ou leur version sont rejetés.

Les sauvegardes appartiennent au serveur et sont stockées dans `garrysmod/data/gvoxel/zones/<map>/`. Elles ne font pas partie des sources publiées.

## Installation et commandes

1. Installer le dossier runtime **gvoxel** dans `garrysmod/addons/`.
2. Redémarrer la partie ou le serveur.
3. En tant qu’administrateur, saisir `vm_give` dans la console pour obtenir l’outil.
4. Sélectionner une zone, lancer l’analyse, puis modifier le terrain.

| Commande de l’outil | Action |
| --- | --- |
| **R maintenu** | Ouvrir les réglages de taille, de rayon et de sélection. |
| **R bref** | Analyser la zone sélectionnée. |
| **Clic gauche** | Retirer de la matière. |
| **Clic droit** | Ajouter de la matière. |
| **Clic molette en mode Custom block** | Placer les quatre points : origine, largeur X, longueur Y et hauteur. |
| **Clic molette après sélection** | Basculer entre déplacement et verrouillage de la boîte. |

Les frameworks de véhicules cités sont optionnels : installez ceux dont vous souhaitez utiliser les véhicules. L’intégration GWater ne fait pas partie de cette version active.

## Multijoueur

**La synchronisation multijoueur est implémentée, mais sa validation complète avec plusieurs joueurs reste à effectuer.**

Le serveur gère la zone, les modifications et les collisions. Les clients reçoivent l’état initial et les modifications ordonnées ; un joueur qui rejoint en cours de partie reçoit les données nécessaires pour reconstruire l’état actuel. Le départ du créateur ne supprime pas la zone.

Les fichiers Lua clients sont transmis par le serveur via le mécanisme de Garry’s Mod : les autres joueurs n’ont pas à copier manuellement le script. Les maps et contenus externes nécessaires aux véhicules utilisés doivent rester disponibles aux clients.

Les outils restent réservés aux administrateurs ; les autres joueurs peuvent voir la zone et interagir avec son environnement physique. La latence et la vitesse de préparation des clients influencent le délai de validation des modifications. Un client qui ne répond pas peut encore retarder les opérations attendant ses accusés de réception.

## Optimisation et état du projet

GVoxel répartit les travaux préparatoires entre plusieurs ticks et privilégie les reconstructions locales. Les données réutilisables sont mises en cache ; les captures, tâches et vues supplémentaires disposent de budgets pour limiter leur coût.

Ces mécanismes réduisent le travail répété, mais ne constituent pas une garantie de FPS ou de temps de creusement. Le coût dépend notamment de la map, du volume sélectionné, des matériaux, des véhicules et du matériel utilisé.

Les tests automatisés couvrent la géométrie, des adaptations de collision, les caches, les permissions et la logique réseau. Ils ne remplacent pas les essais en jeu pour le rendu, les performances, la conduite, les IA et le multijoueur réel.

Pour diagnostiquer une scène, les commandes comprennent notamment `vm_diagnose`, `vm_geometry_stats`, `vm_edit_stats` et `vm_render_stats`.

## Développement

Le projet source contient :

- `lua/` : code de l’addon, réparti entre logique partagée, serveur et client.
- `tools/` : déploiement et préparation des archives.
- `tests/` : vérifications automatisées et adaptateurs moteur.
- `docs/images/` : visuels utilisés par ce README.

Dans l’espace de travail de référence, les sources résident sous `garrysmod/addons/all source file/gvoxel_sources/` et les fichiers déployés sous `garrysmod/addons/gvoxel/`.

```powershell
python -B tests/run_tests.py
python -B tests/run_tests.py --zones
python -B tools/deploy_runtime.py --write
python -B tools/build_workshop.py
```

Les tests utilisent LuaJIT fourni par l’installation de Garry’s Mod. Certaines vérifications optionnelles nécessitent les maps ou addons Workshop correspondants. Le build produit notamment `dist/gvoxel.gma` et `dist/gvoxel-workshop.zip`, sans publication automatique.

Pour signaler un problème, précisez la map, la taille de la zone, les étapes de reproduction, les addons concernés et les erreurs de console. Pour une optimisation, joignez des mesures avant/après et distinguez les tests automatisés des essais réalisés dans le jeu.

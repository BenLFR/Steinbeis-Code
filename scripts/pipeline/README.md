# Pipeline Stundensatz V9

Pipeline modulaire pour le calcul des taux horaires (Stundensatz) et des daily rates HEU.

## 📋 Structure

```
pipeline/
├── run_pipeline.R          # Script principal pour orchestrer le pipeline
├── README.md              # Ce fichier
└── modules/               # Modules du pipeline
    ├── 00_config.R        # Configuration et chemins
    ├── 01_utils.R         # Fonctions utilitaires
    ├── 02_load_data.R     # Chargement des données
    ├── 03_user_mapping.R  # Mapping utilisateurs ↔ HR
    ├── 04_worktime_analysis.R    # Analyse du temps de travail
    ├── 05_master_table.R  # Construction de la table master
    ├── 06_project_classification.R # Classification des projets
    ├── 07_cost_breakdown.R # Répartition des coûts
    ├── 08_heu_gatekeeper.R # Contrôle de cohérence RH vs HEU
    ├── 09_heu_daily_rate.R # Calcul du daily rate HEU
    └── 10_exports.R       # Exports des résultats
```

## 🚀 Utilisation

### Exécution complète du pipeline

```bash
cd scripts/pipeline
Rscript run_pipeline.R
```

### Exécution partielle

```bash
# Exécuter à partir d'un module spécifique (ex: à partir du module 05)
Rscript run_pipeline.R --from=05

# Exécuter uniquement un module spécifique (ex: uniquement le module 09)
# Note: Les modules 00 et 01 (config et utils) seront toujours exécutés en premier
Rscript run_pipeline.R --only=09
```

## 📦 Modules détaillés

### 00 - Configuration
- Définit les chemins vers les données
- Configure la période de reporting
- Paramètres de traitement (entités cibles, bypass incohérences, etc.)

### 01 - Utils
- Fonctions de lecture de données (DATEV, DB)
- Fonctions de normalisation de noms
- Fonctions de calcul de périodes
- Utilitaires divers

### 02 - Load Data
- Chargement des tables de la base de données
- Traitement des données DATEV (payroll)
- Chargement des données Personio (FTE)

### 03 - User Mapping
- Création du mapping utilisateurs ↔ numéros HR
- Auto-correction via DATEV (noms uniques)
- Liaison payroll → du_id
- Identification des personnes multi-CC

### 04 - Worktime Analysis
- Calcul du temps de travail avec prorata multi-WP
- Heures par entité et totales
- Association worktime ↔ workpackages

### 05 - Master Table
- Calcul de la période de reporting dynamique
- Construction de la table master enrichie
- Agrégation payroll, FTE et worktime
- Calcul des Stundensatz (worked_h et contract_h)

### 06 - Project Classification
- Classification des projets par programme de financement
- Identification des projets HEU, H2020, INTERREG, etc.

### 07 - Cost Breakdown
- Répartition des coûts par projet avec prorata
- Calcul des coûts alloués par WP et projet
- Gestion des multi-WP

### 08 - HEU Gatekeeper
- Contrôle de cohérence RH vs HEU
- Détection des incohérences (heures HEU sans FTE/coûts)
- Export des cas problématiques

### 09 - HEU Daily Rate
- Calcul du daily rate HEU avec prorata jour-calendaire
- Traitement des congés parentaux (Elternzeit)
- Cap HEU par personne (215/12 jours × FTE × coverage)
- Contrôle cap vs jours déclarés
- Reporting unifié HEU vs non-HEU

### 10 - Exports
- Export de toutes les tables finales
- Rapports HEU vs non-HEU
- Exports spécifiques (ex: WP 4034)

## 🔧 Configuration

Les paramètres principaux sont définis dans `modules/00_config.R`:

- `dir_db`, `dir_datev`, `dir_fte` : Chemins vers les données
- `target_entities` : Entités cibles (cost centers)
- `period_mode` : Mode de calcul de période ("datev", "union", "manual")
- `allow_incoherent` : Bypass temporaire pour incohérences RH

## 📊 Outputs

Les exports principaux sont générés dans `dir_db`:

- `master_personnes_enriched.csv` : Table master complète
- `cost_by_pr_with_programme.csv` : Coûts par projet avec programme
- `heu_daily_rate_by_person.csv` : Daily rates HEU par personne
- `heu_daily_rate_control.csv` : Contrôle cap vs déclaré
- `heu_final_by_project.csv` : Coûts HEU par projet
- `non_heu_by_project.csv` : Coûts non-HEU par projet
- `reporting_costs_HEU_daily_vs_nonHEU_prorata.csv` : Rapport unifié
- `parental_leave_deductions.csv` : Déductions congés parentaux
- `heu_data_incoherences.csv` : Incohérences détectées

## 🐛 Dépannage

### Erreur "File does not exist"
Vérifiez les chemins dans `00_config.R` et que tous les fichiers de données sont présents.

### Erreur dans un module spécifique
Exécutez le module individuellement pour un debug plus facile:
```bash
Rscript run_pipeline.R --only=05
```

### Incohérences RH
Consultez le fichier `heu_data_incoherences.csv` pour identifier les personnes avec heures HEU mais sans FTE/coûts.

## 📝 Notes de version

### V9 (15-Dec-2025)
- Parental leave deduction (Elternzeit)
- HEU fix + programme via lpc_id
- Dedup fix + dynamic period
- Modularisation du pipeline

## 👤 Maintenance

Pour modifier le pipeline:
1. Éditez le module concerné dans `modules/`
2. Testez avec `--only=XX` pour vérifier le module seul
3. Testez le pipeline complet
4. Documentez les changements importants

---

**Version:** 9.0
**Dernière mise à jour:** 15-Dec-2025

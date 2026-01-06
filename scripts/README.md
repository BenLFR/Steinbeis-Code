# Scripts Steinbeis - Stundensatz & Cost Analysis

Ce répertoire contient les scripts pour le calcul des taux horaires (Stundensatz) et l'analyse des coûts de projets.

## 📁 Structure

```
scripts/
├── pipeline/              # 🚀 Pipeline modulaire V9 (UTILISER CELUI-CI)
│   ├── run_pipeline.R    # Script principal pour lancer le pipeline
│   ├── README.md         # Documentation détaillée du pipeline
│   └── modules/          # Modules du pipeline (00 à 10)
│
├── archive/              # 📦 Anciennes versions (référence uniquement)
│   ├── compute_stundensatz_local.R (V1)
│   ├── compute_stundensatz_local_V2.R
│   ├── ...
│   ├── compute_stundensatz_local_V9_ORIGINAL.R
│   └── README.md
│
├── report_robin_costs.R  # Script de reporting spécifique au projet ROBIN
└── README.md             # Ce fichier
```

## 🎯 Utilisation rapide

### Pipeline Stundensatz V9 (recommandé)

```bash
# Se placer dans le dossier pipeline
cd scripts/pipeline

# Exécuter le pipeline complet
Rscript run_pipeline.R

# Ou exécuter uniquement certains modules
Rscript run_pipeline.R --from=05
Rscript run_pipeline.R --only=09
```

Consultez `pipeline/README.md` pour la documentation complète.

## 📊 Outputs générés

Le pipeline génère les fichiers suivants dans `data/x/Database/`:

### Tables principales
- `master_personnes_enriched.csv` - Table master avec tous les calculs
- `cost_by_pr_with_programme.csv` - Coûts par projet et programme

### HEU (Horizon Europe)
- `heu_daily_rate_by_person.csv` - Daily rates HEU par personne
- `heu_daily_rate_control.csv` - Contrôle cap vs déclaré
- `heu_final_by_project.csv` - Coûts HEU par projet
- `heu_data_incoherences.csv` - Incohérences RH détectées

### Non-HEU et reporting
- `non_heu_by_project.csv` - Coûts non-HEU par projet
- `reporting_costs_HEU_daily_vs_nonHEU_prorata.csv` - Rapport unifié

### Autres
- `parental_leave_deductions.csv` - Déductions congés parentaux
- `inferred_hr_numbers_from_DATEV.csv` - Numéros HR inférés

## 🔧 Configuration

Les chemins et paramètres sont configurés dans `pipeline/modules/00_config.R`:

```r
# Chemins des données
dir_db    <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/Database"
dir_datev <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/datev-data"
dir_fte   <- "C:/Users/loeff/OneDrive/Documents/SEZ/2025/data/x/fte-liste"

# Entités cibles (cost centers)
target_entities <- c("2016","2017","2136")

# Mode de période de reporting
period_mode <- "datev"  # ou "union" ou "manual"
```

## 📝 Modules du pipeline V9

| Module | Nom | Description |
|--------|-----|-------------|
| 00 | config | Configuration et chemins |
| 01 | utils | Fonctions utilitaires |
| 02 | load_data | Chargement des données (DB, DATEV, Personio) |
| 03 | user_mapping | Mapping utilisateurs ↔ HR numbers |
| 04 | worktime_analysis | Analyse du temps de travail |
| 05 | master_table | Construction de la table master enrichie |
| 06 | project_classification | Classification des projets (HEU/non-HEU) |
| 07 | cost_breakdown | Répartition des coûts par projet |
| 08 | heu_gatekeeper | Contrôle de cohérence RH vs HEU |
| 09 | heu_daily_rate | Calcul du daily rate HEU |
| 10 | exports | Exports des résultats finaux |

## 🐛 Dépannage

### Le pipeline ne trouve pas les données
Vérifiez les chemins dans `pipeline/modules/00_config.R` et assurez-vous que:
- Les fichiers DATEV sont dans `dir_datev`
- Les fichiers de base de données sont dans `dir_db` et `dir_db/ben/`
- Le fichier FTE Personio est dans `dir_fte`

### Erreur dans un module spécifique
Consultez les logs du pipeline pour identifier le module en erreur, puis:
```bash
# Exécuter uniquement ce module pour debug
Rscript run_pipeline.R --only=05
```

### Incohérences RH détectées
Le fichier `heu_data_incoherences.csv` liste les personnes avec heures HEU mais sans FTE/coûts.
Vérifiez:
- Les numéros HR dans `d_user.csv` (colonne `du_hr_numbers`)
- Les données Personio (FTE)
- Les données DATEV (payroll)

## 🔄 Migration depuis V8

Si vous utilisiez encore `compute_stundensatz_local_V8.R`:
1. Le script V8 est archivé dans `archive/`
2. Utilisez maintenant `pipeline/run_pipeline.R`
3. Les résultats sont identiques mais la structure est plus claire
4. Vous pouvez réexécuter seulement certaines parties du pipeline

## 📞 Support

Pour toute question sur le pipeline:
1. Consultez `pipeline/README.md` pour la documentation détaillée
2. Vérifiez les logs d'exécution du pipeline
3. Consultez les fichiers de contrôle dans `dir_db/`

---

**Version actuelle:** V9 modulaire
**Dernière mise à jour:** 15-Dec-2025
**Auteur:** Équipe Data Analysis Steinbeis

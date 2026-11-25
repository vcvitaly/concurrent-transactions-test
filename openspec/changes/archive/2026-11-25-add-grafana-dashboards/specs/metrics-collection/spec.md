# Spec Delta

## ADDED Requirements

### Requirement: Stack deploys to a kind cluster
When told the name of the kind cluster it targets, `./deploy.sh` SHALL make the images it builds locally available to that cluster before installing anything that uses them. Without that setting, its behaviour SHALL be unchanged and it SHALL NOT require kind. The README SHALL document the setting.

#### Scenario: Deploy to kind
- **WHEN** `./deploy.sh` runs against a kind cluster with that cluster's name set
- **THEN** the service, speedbump and collector become ready, and the collector scrapes both service replicas

#### Scenario: Setting unset
- **WHEN** `./deploy.sh` runs without the kind cluster setting
- **THEN** it doesn't call kind and behaves as before

## MODIFIED Requirements

### Requirement: History is independent of the cluster
The store's data SHALL survive cluster teardown and redeploy, and restarts of the store itself. The data SHALL be deleted only by an explicit, documented reset command, which asks for confirmation unless told not to. The reset command SHALL delete only the store's data, unless it is explicitly told to also delete other data in the metrics stack.

#### Scenario: Cluster teardown then redeploy
- **WHEN** metrics are collected, `./deploy.sh --teardown` runs, and then `./deploy.sh` runs again
- **THEN** queries for the period before the teardown still return the earlier data

#### Scenario: Cluster is down
- **WHEN** the cluster has been torn down and not redeployed
- **THEN** the store still answers queries for the stored history

#### Scenario: Store restart
- **WHEN** the store is stopped and started again with the documented commands
- **THEN** the earlier data is still returned by queries

#### Scenario: Reset asks first
- **WHEN** the reset command runs without the no-confirmation flag
- **THEN** it asks for confirmation before deleting any data, naming what it will delete

#### Scenario: Reset outside a terminal without confirmation
- **WHEN** the reset command runs without the no-confirmation flag and not in a terminal
- **THEN** it exits non-zero, deletes nothing, and names the data it would have deleted

#### Scenario: Reset deletes only the store's data
- **WHEN** the reset command runs without any option to include other data, and is confirmed
- **THEN** the store's data is deleted, any other data in the metrics stack is kept, and the command says which data it deleted and which it kept

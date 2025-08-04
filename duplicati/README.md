# duplicati

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 2.1.0.125](https://img.shields.io/badge/AppVersion-2.1.0.125-informational?style=flat-square)
duplicati Helm Chart (Backups)

## Source Code

* <https://github.com/linuxserver/docker-duplicati>

## Requirements

Kubernetes: `>=1.16.0-0`

## TL;DR

```console
helm repo add dev-shynkar https://github.com/dev-shynkar/HelmCharts/
helm repo update
helm install duplicati dev-shynkar/duplicati
```

## Installing the Chart

To install the chart in namespace 'backups'
```console
helm install duplicati dev-shynkar/duplicati --namespace backups --set namespace=backups
```

## Uninstalling the Chart

To uninstall the `duplicati` deployment

```console
helm uninstall duplicati
```

The command removes all the Kubernetes components associated with the chart **including persistent volumes** and deletes the release.

## Configuration

Read through the [values.yaml](./values.yaml) file. It has several commented out suggested values.
Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart.

```console
helm install duplicati dev-shynkar/duplicati -f values.yaml
```

## Changelog

### Version 0.1.0

#### Added

First Version Full working Released

# Dev-Shynkar Helm Charts Repository

## 🚀 Додавання репозиторію

```bash
helm repo add dev-shynkar https://dev-shynkar.github.io/HelmCharts/
helm repo update
```

## 🔍 Пошук чартів

```bash
helm search repo dev-shynkar
```

## 📦 Встановлення Duplicati

```bash
# Базове встановлення
helm install my-duplicati dev-shynkar/duplicati

# З налаштуваннями
helm install my-duplicati dev-shynkar/duplicati \
  --set service.type=NodePort \
  --set persistence.enabled=true
```

## 🔄 Оновлення

```bash
helm upgrade my-duplicati dev-shynkar/duplicati
```

---
*Автоматично оновлюється через GitHub Actions*

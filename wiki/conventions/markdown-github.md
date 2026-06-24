# Convenções Markdown / GitHub

## Comportamento do GitHub com numeração

O GitHub renderiza markdown de forma diferente do esperado em dois cenários:

### Headers numerados

Headers com numeração são convertidos para algarismos romanos:
```markdown
## 1. Título     → renderiza como "i. Título"
## 2. Título     → renderiza como "ii. Título"
```

**Correção**: escapar o ponto com barra invertida:
```markdown
## 1\. Título    → renderiza como "1. Título"
## 2\. Título    → renderiza como "2. Título"
```

### Listas ordenadas dentro de bullets

Listas numeradas que estão aninhadas dentro de um bullet (`- item`) também são convertidas para romano:
```markdown
- Item
    1. Passo um    → renderiza como "i. Passo um"
    2. Passo dois  → renderiza como "ii. Passo dois"
```

**Correção**: usar HTML `<ol><li>`:
```markdown
- Item
    <ol>
    <li>Passo um</li>
    <li>Passo dois</li>
    </ol>
```

### Listas ordenadas soltas (sem bullet pai)

Listas numeradas sem bullet pai funcionam normalmente com markdown padrão:
```markdown
1. Passo um     → renderiza como "1. Passo um"
2. Passo dois   → renderiza como "2. Passo dois"
```

## Validação antes de commit

Para testar a renderização do markdown antes de enviar ao GitHub:

```bash
pip install grip
grip <arquivo>.md
```

Abra `localhost:6419` no browser para ver a renderização idêntica ao GitHub.

## Regra geral

- **Headers numerados**: sempre usar `## 1\. Título` (com escape).
- **Listas ordenadas dentro de bullets**: sempre usar `<ol><li>` (HTML).
- **Listas ordenadas soltas**: pode usar markdown `1. 2. 3.` normalmente.
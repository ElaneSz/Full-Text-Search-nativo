# Full-Text Search (FTS) Nativo no PostgreSQL — Guia Prático e Scripts de Teste

Este repositório contém todos os exemplos práticos, consultas SQL e explicações desenvolvidas para a demonstração e seminário sobre **Full-Text Search (FTS) Nativo no PostgreSQL**.

---

## 📌 Sumário

1. [Visão Geral e Pré-requisitos](#-visão-geral-e-pré-requisitos)
2. [Criação do Esquema e Inserção de Dados](#1-criação-do-esquema-e-inserção-de-dados)
3. [Demonstração 0: Conceitos Base e Stemming](#2-demonstração-0-conceitos-base-e-stemming)
4. [Demonstração 1: Limitações da Busca com `LIKE`](#3-demonstração-1-limitações-da-busca-com-like)
5. [Demonstração 2: Busca Semântica e Normalização com FTS](#4-demonstração-2-busca-semântica-e-normalização-com-fts)
6. [Demonstração 3: Análise de Desempenho com `EXPLAIN ANALYZE` e Índice GIN](#5-demonstração-3-análise-de-desempenho-com-explain-analyze-e-índice-gin)
7. [Demonstração 4: Ranking de Relevância (`ts_rank`) e Destaque (`ts_headline`)](#6-demonstração-4-ranking-de-relevância-ts_rank-e-destaque-ts_headline)
8. [Como Executar os Testes](#-como-executar-os-testes)

---

## 🚀 Visão Geral e Pré-requisitos

O mecanismo de **Full-Text Search (FTS)** nativo do PostgreSQL permite realizar buscas textuais avançadas de alto desempenho diretamente no banco de dados relacional, sem a necessidade de ferramentas de busca externas (como Elasticsearch ou Solr) para a maioria dos casos de uso.

### Pré-requisitos do SGBD:
* **PostgreSQL 12+** (necessário para suporte a colunas geradas armazenadas com `GENERATED ALWAYS AS ... STORED`).
* Dicionário do idioma Português ativado (`pg_catalog.portuguese`).

---

## 1. Criação do Esquema e Inserção de Dados

Nesta etapa, criamos a tabela `ordens_servico` contendo uma **coluna gerada** (`search_vector`) do tipo `tsvector`. Utilizamos a função `setweight()` para atribuir pesos de relevância aos diferentes campos da Ordem de Serviço:
* **Peso A:** `problema_cliente` (maior importância na busca).
* **Peso B:** `diagnostico` (conteúdo técnico).
* **Peso C:** `mecanico_responsavel` (menor peso).

```sql
-- 1. Criação da Tabela com Coluna Gerada armazenada (STORED)
CREATE TABLE ordens_servico (
    id SERIAL PRIMARY KEY,
    problema_cliente VARCHAR(200) NOT NULL,
    diagnostico TEXT NOT NULL,
    mecanico_responsavel VARCHAR(100),
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('portuguese', coalesce(problema_cliente, '')), 'A') ||
        setweight(to_tsvector('portuguese', coalesce(diagnostico, '')), 'B') ||
        setweight(to_tsvector('portuguese', coalesce(mecanico_responsavel, '')), 'C')
    ) STORED
);

-- 2. Inserção de Dados de Exemplo para Testes
INSERT INTO ordens_servico (problema_cliente, diagnostico, mecanico_responsavel) VALUES
('Carro com barulho no motor', 'A oficina realizou a manutenção preventiva. Correia dentada trocada.', 'João Silva'),
('Travões a falhar', 'Substituição das pastilhas de travão e disco. Veículo testado.', 'Carlos Mendes'),
('Vazamento de óleo', 'Foi detetada uma fissura no cárter. O mecânico consertou a peça.', 'João Silva'),
('Motor aquece muito', 'Problema no radiador. Realizadas várias manutenções no sistema de arrefecimento.', 'Ana Costa'),
('Revisão geral', 'Correias inspecionadas, óleo trocado. Todos os veículos desta frota foram revistos.', 'Carlos Mendes');
```

---

## 2. Demonstração 0: Conceitos Base e Stemming

### 2.1 Explorando o `tsvector`
A função `to_tsvector` converte o texto bruto em uma lista de lexemas normalizados e suas posições no texto. As *stop words* (como "Os", "na") são desconsideradas automaticamente.

```sql
SELECT to_tsvector('portuguese', 'Os mecânicos consertaram vários veículos na oficina.');
-- Resultado esperado: 'consert':3 'mecan':2 'oficin':7 'veicul':5
```

### 2.2 Explorando o `tsquery` e Operadores Lógicos
A função `to_tsquery` constrói a consulta aplicando os operadores booleanos e posicionais:
* `&` (AND) / `|` (OR) / `!` (NOT)
* `<->` (Operador de proximidade / frases)

```sql
-- Operadores & (AND) e | (OR)
SELECT to_tsquery('portuguese', 'mecanico & (veiculo | motor)');

-- Operador ! (NOT - mecânico que não seja de moto)
SELECT to_tsquery('portuguese', 'mecanico & !moto');

-- Operador <-> (Proximidade - termos adjacentes)
SELECT to_tsquery('portuguese', 'troca <-> oleo');

-- Operador automático para frases completas (phraseto_tsquery)
SELECT phraseto_tsquery('portuguese', 'troca de oleo');
```

### 2.3 Normalização por Stemmer (Radicalização)
O stemmer reduz palavras flexionadas, conjugações e plurais à sua forma raiz (*lexema*).

```sql
SELECT to_tsvector('portuguese', 'O mecânico consertou o carro. O conserto foi rápido porque ele conserta bem.');
-- Resultado: 'bem':13 'carro':5 'consert':3,7,12 'mecan':2 'rapid':9
-- "consertou", "conserto" e "conserta" são mapeados para o lexema único 'consert'.
```

---

## 3. Demonstração 1: Limitações da Busca com `LIKE`

A busca tradicional utilizando o operador `LIKE` realiza uma correspondência rígida de caracteres (subcadeia).

```sql
-- Busca por subcadeia exata
SELECT id, problema_cliente, diagnostico 
FROM ordens_servico 
WHERE diagnostico LIKE '%manutencao%'; 
```

### ❌ Limitações do `LIKE`:
1. **Falha de Acentuação e Caracteres:** A consulta por `'manutencao'` não encontra `'manutenção'`.
2. **Incapacidade de Tratar Plural/Flexão:** Não encontra variações como `'manutenções'`.
3. **Desempenho Ruim:** O uso do coringa no início (`%termo%`) força uma varredura sequencial completa na tabela (*Seq Scan*), inviabilizando índices B-Tree tradicionais.

---

## 4. Demonstração 2: Busca Semântica e Normalização com FTS

Ao utilizar a busca por vetor (`search_vector @@ to_tsquery(...)`), o PostgreSQL compara lexemas raiz em vez de cadeias brutas.

```sql
-- Encontra registros contendo "manutenção", "manutenções", "consertou", "consertou-se", etc.
SELECT id, problema_cliente, diagnostico 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'manutencao | consertar');
```

### ✅ Vantagens do FTS:
* Trata acentuação e caixa (case-insensitive) automaticamente.
* Captura plurais e formas conjugadas de verbos.
* Utiliza a coluna indexada `search_vector`.

---

## 5. Demonstração 3: Análise de Desempenho com `EXPLAIN ANALYZE` e Índice GIN

### 5.1 Consulta Sem Índice (Varredura Sequencial)
Sem um índice apropriado, o plano de execução realiza um `Seq Scan`:

```sql
EXPLAIN ANALYZE
SELECT id, problema_cliente 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'motor');
```

### 5.2 Criação do Índice GIN (Generalized Inverted Index)
O índice GIN cria uma estrutura invertida de palavras para chaves do tipo `tsvector`.

```sql
CREATE INDEX idx_ordens_search ON ordens_servico USING GIN (search_vector);
```

### 5.3 Teste de Execução Com Índice GIN
*Nota: Em tabelas pequenas com poucos registros, o otimizador do PostgreSQL prefere `Seq Scan` por ser mais rápido na memória. Desativamos temporariamente `enable_seqscan` para demonstrar o comportamento do índice em tabelas de grande porte.*

```sql
-- Força o otimizador a utilizar o índice GIN para fins didáticos
SET enable_seqscan = OFF;

EXPLAIN ANALYZE
SELECT id, problema_cliente 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'motor');
-- Plano retornado: Bitmap Index Scan on idx_ordens_search

-- Reativa o comportamento padrão do otimizador
SET enable_seqscan = ON;
```

---

## 6. Demonstração 4: Ranking de Relevância (`ts_rank`) e Destaque (`ts_headline`)

### 6.1 Inserção de Registro de Teste para Ranking
```sql
INSERT INTO ordens_servico (problema_cliente, diagnostico, mecanico_responsavel) VALUES
('Motor travado e motor aquecendo', 'O motor foi desmontado. Cliente relatou que o motor antigo fazia barulho de motor fundido. Motor testado.', 'Ana Costa');
```

### 6.2 Consulta com Ordenação por Relevância e Highlight no Texto
* `ts_rank()`: Calcula a pontuação de relevância considerando a frequência dos termos e os pesos atribuídos na coluna gerada (A, B, C).
* `ts_headline()`: Extrai trecho do documento destacando os termos pesquisados através de delimitadores customizáveis (`<<` e `>>`).

```sql
SELECT 
    mecanico_responsavel,
    ROUND(CAST(ts_rank(search_vector, to_tsquery('portuguese', 'motor')) AS NUMERIC), 4) AS relevancia,
    ts_headline(
        'portuguese', 
        diagnostico, 
        to_tsquery('portuguese', 'motor'),
        'StartSel=<<, StopSel=>>, MaxWords=30, MinWords=10'
    ) AS trecho_destacado
FROM ordens_servico
WHERE search_vector @@ to_tsquery('portuguese', 'motor')
ORDER BY relevancia DESC;
```



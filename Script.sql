-- 1. Criação da Tabela com Coluna Gerada (
-- Utilizamos pesos: A (Problema relatado), B (Diagnóstico/Conteúdo), C (Mecânico)
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

-- 2. Inserção de Dados de Exemplo (Demonstra o Stemming)
INSERT INTO ordens_servico (problema_cliente, diagnostico, mecanico_responsavel) VALUES
('Carro com barulho no motor', 'A oficina realizou a manutenção preventiva. Correia dentada trocada.', 'João Silva'),
('Travões a falhar', 'Substituição das pastilhas de travão e disco. Veículo testado.', 'Carlos Mendes'),
('Vazamento de óleo', 'Foi detetada uma fissura no cárter. O mecânico consertou a peça.', 'João Silva'),
('Motor aquece muito', 'Problema no radiador. Realizadas várias manutenções no sistema de arrefecimento.', 'Ana Costa'),
('Revisão geral', 'Correias inspecionadas, óleo trocado. Todos os veículos desta frota foram revistos.', 'Carlos Mendes');





-- DEMONSTRAÇÃO 0: Conceitos Base e Stemming 

-- 1. Explorando o tsvector 
-- Palavras como "Os", "vários" e "na" desaparecem, e as posições são mapeadas.
SELECT to_tsvector('portuguese', 'Os mecânicos consertaram vários veículos na oficina.');

-- 2. Explorando o tsquery e os seus operadores (&, |, !, <->)
-- Operador & (AND) e | (OR)
SELECT to_tsquery('portuguese', 'mecanico & (veiculo | motor)');

-- Operador ! (NOT - mecânico, mas que não seja de moto)
SELECT to_tsquery('portuguese', 'mecanico & !moto');

-- Operador <-> (Proximidade - palavras imediatamente seguidas na frase)
SELECT to_tsquery('portuguese', 'troca <-> oleo');
-- Nota: phraseto_tsquery faz isto automaticamente com frases
SELECT phraseto_tsquery('portuguese', 'troca de oleo');

-- 3. Demonstração do Stemmer em Português (Normalização de palavras flexionadas)
-- "consertou", "conserto" e "conserta" são todos reduzidos ao lexema raiz 'consert'.
SELECT to_tsvector('portuguese', 'O mecânico consertou o carro. O conserto foi rápido porque ele conserta bem.');









-- DEMONSTRAÇÃO 1: A Limitação do LIKE
-- Apenas encontra a palavra exata. Não encontra "manutenções" ou "manutenção".
SELECT id, problema_cliente, diagnostico 
FROM ordens_servico 
WHERE diagnostico LIKE '%manutencao%'; 
-- Retorna vazio (Problema de acentuação e plural ignorados)




-- DEMONSTRAÇÃO 2: Stemming e Busca Semântica com FTS 
-- Encontra "manutenção", "manutenções", "consertou", etc.
SELECT id, problema_cliente, diagnostico 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'manutencao | consertar');






-- DEMONSTRAÇÃO 3: Análise de Performance com EXPLAIN ANALYZE 
-- 3.1 Consulta normal (Mostra o Seq Scan, varrendo toda a tabela)
EXPLAIN ANALYZE
SELECT id, problema_cliente 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'motor');

-- 3.2 Criação do Índice GIN
CREATE INDEX idx_ordens_search ON ordens_servico USING GIN (search_vector);

-- Como a nossa tabela de testes é muito pequena, o PostgreSQL 
-- vai preferir o Seq Scan. Para efeitos didáticos, vamos proibir o Seq Scan 
-- temporariamente para forçar o banco a demonstrar o uso do índice.
SET enable_seqscan = OFF;

-- 3.4 Executamos o EXPLAIN novamente para mostrar o uso do "Bitmap Index Scan"
EXPLAIN ANALYZE
SELECT id, problema_cliente 
FROM ordens_servico 
WHERE search_vector @@ to_tsquery('portuguese', 'motor');

-- 3.5 Reativamos o comportamento normal do banco (Boa prática)
SET enable_seqscan = ON;






-- DEMONSTRAÇÃO 4: Ranking e Highlight 
-- Mostra os resultados ordenados por relevância e com as palavras destacadas

-- 1. Inserimos esse caso de teste para demonstrar o ranking e highlight
INSERT INTO ordens_servico (problema_cliente, diagnostico, mecanico_responsavel) VALUES
('Motor travado e motor aquecendo', 'O motor foi desmontado. Cliente relatou que o motor antigo fazia barulho de motor fundido. Motor testado.', 'Ana Costa');


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

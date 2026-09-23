-- Adiciona "sexo" (masculino/feminino, extraído pela IA quando o currículo informa
-- explicitamente) à vw_triagem, como dado de auditoria/estatística — NÃO é filtro de
-- busca (Filtros avançados não usa esta coluna; ver dashboard.js para o resumo).
-- Coluna precisa ir no fim do SELECT: Postgres não deixa renomear/inserir coluna no
-- meio de uma view existente via CREATE OR REPLACE VIEW.
CREATE OR REPLACE VIEW public.vw_triagem AS
 SELECT c.id,
    c.dados_pessoais ->> 'nome'::text AS nome,
    c.dados_pessoais ->> 'telefone'::text AS telefone,
    c.dados_pessoais ->> 'telefone_e164'::text AS telefone_e164,
    c.dados_pessoais ->> 'email'::text AS email,
    c.dados_pessoais ->> 'cidade'::text AS cidade,
    c.status,
    c.aderencia_vaga,
    c.vaga_confirmada_rh,
    c.recebido_em,
    c.selecionado_em,
    v.id AS vaga_id,
    v.titulo AS vaga_titulo,
    s.nome AS setor_nome,
    s.cor AS setor_cor,
    s.icone AS setor_icone,
    a.nota,
    a.resumo_nota,
    a.resumo_ia,
    a.pontos_fortes,
    a.lacunas,
    a.requisitos_faltantes,
    a.eliminado_por_regra,
    a.divergencia_detectada,
    cur.storage_path,
    cur.nome_arquivo,
    cur.origem,
    r.total_envios,
    r.total_envios > 1 AS e_reincidente,
    c.dados_pessoais ->> 'sexo'::text AS sexo
   FROM candidaturas c
     LEFT JOIN vagas v ON v.id = c.vaga_id
     LEFT JOIN setores s ON s.id = v.setor_id
     LEFT JOIN remetentes r ON r.id = c.remetente_id
     LEFT JOIN curriculos cur ON cur.candidatura_id = c.id
     LEFT JOIN LATERAL ( SELECT av.id,
            av.candidatura_id,
            av.vaga_id,
            av.nota,
            av.resumo_nota,
            av.resumo_ia,
            av.pontos_fortes,
            av.lacunas,
            av.requisitos_faltantes,
            av.eliminado_por_regra,
            av.versao_criterios,
            av.modelo_ia,
            av.tokens_entrada,
            av.tokens_saida,
            av.duracao_ms,
            av.sequencia,
            av.divergencia_detectada,
            av.created_at
           FROM avaliacoes av
          WHERE av.candidatura_id = c.id
          ORDER BY av.sequencia DESC
         LIMIT 1) a ON true
  WHERE c.status_registro = 'ativo'::status_registro;

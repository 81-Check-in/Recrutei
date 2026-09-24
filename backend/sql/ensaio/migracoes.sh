# Lista única das migrações e dos testes de SQL do ensaio (lida por ensaio.sh, rapido.sh e integracao/resetar-banco.sh).
# Ao criar uma migração nova: acrescente aqui (na ordem) e, se ela tiver teste, o teste em TESTES_SQL.
# Cada migração roda em uma execução separada (a 020 e a 027 precisam disso: valores novos de enum).
MIGRACOES=(
  020_banco_talentos_tipos.sql
  021_banco_talentos_modelo.sql
  022_banco_talentos_regras.sql
  023_banco_talentos_sanitizacao.sql
  024_banco_talentos_views.sql
  025_banco_talentos_migracao_dados.sql
  026_banco_talentos_ajustes.sql
  027_banco_talentos_tipos2.sql
  028_banco_talentos_etapa1.sql
  029_banco_talentos_etapa2.sql
  030_banco_talentos_etapa3.sql
  031_qualificacao_curriculo.sql
  032_email_de_envio.sql
  033_selecao_por_qualificacao.sql
  034_atribuir_grava_qualificacao.sql
  035_catalogo_setores_cargos_niveis.sql
  036_niveis_habilitar_desabilitar.sql
  037_candidatos_da_vaga_views.sql
)
# Testes que rodam sobre o banco já migrado (cada um termina em ROLLBACK)
TESTES_SQL=(
  ensaio/10_teste_regras.sql
  ensaio/11_teste_sanitizacao.sql
  ensaio/14_teste_etapa1.sql
  ensaio/15_teste_etapa2.sql
  ensaio/16_teste_etapa3.sql
  ensaio/17_teste_qualificacao.sql
  ensaio/18_teste_email_de_envio.sql
  ensaio/19_teste_selecao.sql
  ensaio/21_teste_niveis.sql
)

// ═══════════════════════════════════════════════════════════
//  CONSIDERAÇÕES DO RH SOBRE O CANDIDATO
//  Anotações (ex.: depois da entrevista) presas ao CANDIDATO, não à candidatura: se ele volta ao Banco de Talentos,
//  as considerações continuam com ele, com quem escreveu, quando e sobre qual vaga. Aparecem no cadastro do banco,
//  no cadastro da candidatura ("Em processo") e na aba "Considerações" do resultado da entrevista.
//  Gravação por registrar_consideracao / excluir_consideracao (backend/sql/030); o painel não escreve na tabela.
//  Só o autor ou o administrador excluem. A auditoria guarda que houve, nunca o texto.
// ═══════════════════════════════════════════════════════════

// Os três lugares onde a lista aparece: prefixo → onde ficam a lista (data-candidato) e o campo de texto
const LISTAS_CONSIDERACOES = ['t', 'd', 'res'];

async function buscarConsideracoes(candidatoId) {
  const { data, error } = await db.from('vw_consideracoes').select('*')
    .eq('candidato_id', candidatoId).order('criado_em', { ascending: false });
  if (error) { toast('Erro ao carregar as considerações: ' + mensagemErro(error), 'erro'); return []; }
  return data || [];
}

function htmlConsideracoes(lista) {
  if (!lista.length) return '<span class="sem-dados">Nenhuma consideração ainda</span>';
  return lista.map(n => {
    const podeExcluir = n.autor_id === app.usuario?.id || ehAdministrador();
    return `<div class="consid-item">
      <div class="consid-topo"><strong>${escapeHtml(n.autor_nome || 'RH')}</strong><span>${fmtDataHora(n.criado_em)}</span>
        ${podeExcluir ? `<button type="button" class="consid-del" title="Excluir esta consideração" aria-label="Excluir consideração"
          onclick="excluirConsideracaoPainel('${n.id}')"><i class="ti ti-trash"></i></button>` : ''}</div>
      ${n.vaga_titulo ? `<div class="consid-ctx"><i class="ti ti-briefcase"></i>${escapeHtml(n.vaga_titulo)}${n.entrevista_id ? ' · após a entrevista' : ''}</div>` : ''}
      <p>${escapeHtml(n.texto)}</p></div>`;
  }).join('');
}

// Desenha a lista de um prefixo ('t' cadastro do banco, 'd' cadastro da candidatura, 'res' resultado da entrevista)
async function mostrarConsideracoes(prefixo, candidatoId, entrevistaId = null) {
  const el = $(`#${prefixo}-consid-lista`);
  if (!el) return;
  el.dataset.candidato = candidatoId || '';
  el.dataset.entrevista = entrevistaId || '';
  $(`#${prefixo}-consid`).value = '';
  if (!candidatoId) { el.innerHTML = ''; return; }
  await recarregarConsideracoes(prefixo);
}

async function recarregarConsideracoes(prefixo) {
  const el = $(`#${prefixo}-consid-lista`);
  const id = el?.dataset.candidato;
  if (!id) return;
  const lista = await buscarConsideracoes(id);
  if (el.dataset.candidato !== id) return;            // abriu outro candidato enquanto esta consulta esperava
  el.innerHTML = htmlConsideracoes(lista);
  if (prefixo === 'res') $('#res-consid-n').textContent = lista.length ? `(${lista.length})` : '';
}

const recarregarTodasConsideracoes = () => Promise.all(LISTAS_CONSIDERACOES.map(recarregarConsideracoes));

async function adicionarConsideracao(prefixo) {
  const el = $(`#${prefixo}-consid-lista`);
  const campo = $(`#${prefixo}-consid`);
  const texto = campo.value.trim();
  if (!el?.dataset.candidato) return;
  if (!texto) { toast('Escreva a consideração', 'erro'); return; }
  const { error } = await db.rpc('registrar_consideracao', {
    p_candidato_id: el.dataset.candidato, p_texto: texto, p_entrevista_id: el.dataset.entrevista || null });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  campo.value = '';
  toast('Consideração registrada no cadastro do candidato');
  await recarregarTodasConsideracoes();
}

async function excluirConsideracaoPainel(id) {
  if (!await confirmar({
    titulo: 'Excluir consideração', rotulo: 'Excluir', perigo: true,
    mensagem: 'Excluir esta consideração do cadastro do candidato? Isto não pode ser desfeito.'
  })) return;
  const { error } = await db.rpc('excluir_consideracao', { p_id: id });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  toast('Consideração excluída');
  await recarregarTodasConsideracoes();
}

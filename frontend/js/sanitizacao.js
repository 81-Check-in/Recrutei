// ═══════════════════════════════════════════════════════════
//  SANITIZAÇÃO DO BANCO DE TALENTOS
//  O sistema NÃO apaga nada sozinho: a cada ciclo (2 meses, configurável) a rotina gera esta lista de
//  SUGESTÕES, cada uma com motivo e prioridade, e o RH decide — Manter, Inativar ou Excluir definitivamente.
//  Nada acontece sem a confirmação explícita abaixo; toda decisão fica registrada (quem, quando, o quê).
//  Regras e pesos são parâmetros de Configurações; a lógica está em backend/sql/023.
//  Permissões: manter e inativar = qualquer usuário ativo; excluir definitivamente = só administrador.
// ═══════════════════════════════════════════════════════════

const estadoSanitizacao = novoEstadoLista(50);
const selecaoSanitizacao = new Set();          // ids marcados (a seleção sobrevive a "carregar mais")
let decisaoSanitizacao = null;                 // { ids, decisao } do modal aberto
let mesesPadraoAdiar = 6;

const PRIORIDADE_PILL = { alta: ['pill-red', 'Alta'], media: ['pill-yellow', 'Média'], baixa: ['pill-gray', 'Baixa'] };
const DECISAO_PILL = {
  mantido:   ['pill-green', 'Mantido'],
  inativado: ['pill-gray',  'Inativado'],
  excluido:  ['pill-red',   'Excluído'],
  expirada:  ['pill-gray',  'Expirada']
};

const CABECALHO_PENDENTES = `<tr><th style="width:36px"><input type="checkbox" id="san-todas" aria-label="Selecionar todas as exibidas" onchange="alternarTodasSanitizacao(this.checked)"></th>
  <th>Candidato</th><th>Sugestão da IA</th><th>Motivo da sugestão</th><th>Prioridade</th><th>Última movimentação</th><th></th></tr>`;
const CABECALHO_DECIDIDAS = `<tr><th>Candidato</th><th>Decisão</th><th>Decidido por</th><th>Quando</th><th>Observação</th><th>Motivo da sugestão</th></tr>`;

function maisSanitizacao() {
  const btn = $('#san-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoSanitizacao.limite += estadoSanitizacao.tamanhoPagina;
  return carregarSanitizacao();
}

// Badge do menu e linha do dashboard: quantas sugestões esperam decisão
function atualizarBadgeSanitizacao(total) {
  const badge = $('#nav-san-badge');
  if (!badge) return;
  badge.textContent = total > 99 ? '99+' : total;
  badge.style.display = total > 0 ? 'inline-flex' : 'none';
  badge.setAttribute('aria-label', `${total} sugestões de sanitização pendentes`);
}

// Quando saiu a última lista, quando sai a próxima e quantas esperam decisão
async function carregarResumoSanitizacao() {
  const [ciclos, config, pendentes] = await Promise.all([
    db.from('sanitizacao_ciclos').select('gerada_em,origem,total_sugeridas').order('gerada_em', { ascending: false }).limit(1),
    db.from('configuracoes').select('chave,valor').in('chave', ['sanitizacao_intervalo_meses', 'sanitizacao_adiar_meses']),
    db.from('sanitizacao_sugestoes').select('prioridade').eq('status', 'pendente').limit(10000)
  ]);
  const el = $('#san-ciclo');
  if (ciclos.error || pendentes.error) { el.textContent = mensagemErro(ciclos.error || pendentes.error); return; }

  const valor = chave => Number((config.data || []).find(c => c.chave === chave)?.valor);
  const intervalo = valor('sanitizacao_intervalo_meses') || 2;
  mesesPadraoAdiar = valor('sanitizacao_adiar_meses') || 6;

  const por = { alta: 0, media: 0, baixa: 0 };
  (pendentes.data || []).forEach(p => { por[p.prioridade]++; });
  const total = (pendentes.data || []).length;
  atualizarBadgeSanitizacao(total);

  const ultimo = ciclos.data?.[0];
  let quando = 'Nenhuma lista gerada ainda — a rotina gera a primeira no próximo ciclo.';
  if (ultimo) {
    const proxima = new Date(ultimo.gerada_em);
    proxima.setMonth(proxima.getMonth() + intervalo);
    quando = `Última lista: ${fmtData(ultimo.gerada_em)} (${ultimo.origem === 'job' ? 'automática' : 'gerada por um administrador'}, ` +
             `${ultimo.total_sugeridas} sugestões). Próxima: ${fmtData(proxima.toISOString())} · ciclo de ${intervalo} ${intervalo === 1 ? 'mês' : 'meses'}.`;
  }
  el.textContent = `${total} pendente${total === 1 ? '' : 's'}` +
    (total ? ` (alta ${por.alta} · média ${por.media} · baixa ${por.baixa})` : '') + ' — ' + quando;
}

// ── Lista ──
function montarConsultaSanitizacao() {
  const decididas = $('#san-visao').value === 'decididas';
  const prioridade = $('#san-prioridade').value;
  const busca = $('#san-busca').value.trim();

  let q = db.from('vw_sanitizacao_sugestoes').select('*', { count: 'exact' });
  q = decididas ? q.neq('status', 'pendente') : q.eq('status', 'pendente');
  if (prioridade && !decididas) q = q.eq('prioridade', prioridade);
  if (busca) q = q.ilike('nome', `%${busca}%`);
  return decididas
    ? q.order('decidido_em', { ascending: false })
    : q.order('pontos', { ascending: false }).order('ultima_movimentacao', { ascending: true }).order('id');
}

// O resumo (selo do menu, última/próxima lista) carrega em paralelo com a lista; a função só termina com os dois prontos
async function carregarSanitizacao() {
  const resumo = carregarResumoSanitizacao();
  try { await desenharListaSanitizacao(); } finally { await resumo; }
}

async function desenharListaSanitizacao() {
  const el = $('#san-body');
  const decididas = $('#san-visao').value === 'decididas';
  $('#san-head').innerHTML = decididas ? CABECALHO_DECIDIDAS : CABECALHO_PENDENTES;
  $$('.san-so-admin').forEach(b => { b.style.display = ehAdministrador() ? '' : 'none'; });
  $('#san-btn-gerar').style.display = ehAdministrador() ? 'inline-flex' : 'none';
  $('#san-sel-alta').style.display = decididas ? 'none' : 'inline-flex';

  const chave = JSON.stringify([$('#san-visao').value, $('#san-prioridade').value, $('#san-busca').value]);
  paginaInicialSeFiltroMudou(estadoSanitizacao, chave);
  if (estadoSanitizacao.limite === estadoSanitizacao.tamanhoPagina) {
    el.innerHTML = '<tr><td colspan="7"><div class="estado-vazio"><i class="ti ti-loader-2 girando"></i><p>Carregando...</p></div></td></tr>';
  }

  const versao = ++estadoSanitizacao.versao;
  const { data, error, count } = await montarConsultaSanitizacao().limit(estadoSanitizacao.limite);
  if (versao !== estadoSanitizacao.versao) return;      // mudou a visão/filtro enquanto esta consulta esperava: descarta a antiga
  if (error) {
    el.innerHTML = `<tr><td colspan="7"><div class="estado-vazio erro"><i class="ti ti-alert-triangle"></i><p>${escapeHtml(mensagemErro(error))}</p></div></td></tr>`;
    destravarBotaoMais($('#san-mais'));
    return;
  }
  estadoSanitizacao.total = count ?? data.length;
  atualizarPaginacao($('#san-mais'), estadoSanitizacao, $('#san-contador'), decididas ? ' decisões' : ' sugestões');

  if (!data.length) {
    el.innerHTML = `<tr><td colspan="7"><div class="estado-vazio"><i class="ti ti-circle-check"></i>
      <p>${decididas ? 'Nenhuma decisão registrada ainda' : 'Nenhuma sugestão pendente'}</p>
      <span>${decididas ? '' : 'Quando a rotina gerar a próxima lista, os candidatos sugeridos aparecem aqui'}</span></div></td></tr>`;
    atualizarBarraLote();
    return;
  }

  el.innerHTML = data.map(decididas ? linhaDecidida : linhaPendente).join('');
  atualizarBarraLote();
}

const nomeSugestao = s => s.nome || 'Candidato excluído';
const abrirCandidatoLink = s => s.candidato_id && s.nome
  ? `<a href="#" class="link-nome" onclick="event.preventDefault();abrirTalento('${s.candidato_id}')">${escapeHtml(s.nome)}</a>`
  : `<span class="sem-dados">${nomeSugestao(s)}</span>`;

function linhaPendente(s) {
  const [cls, lbl] = PRIORIDADE_PILL[s.prioridade];
  const sug = [s.area_sugerida, s.cargo_sugerido, rotuloNivel(s.nivel_sugerido)].filter(Boolean).join(' / ');
  const marcada = selecaoSanitizacao.has(s.id);
  return `<tr class="${marcada ? 'linha-sel' : ''}" data-id="${s.id}">
    <td><input type="checkbox" class="san-chk" data-id="${s.id}" ${marcada ? 'checked' : ''}
         aria-label="Selecionar ${escapeHtml(nomeSugestao(s))}" onchange="alternarSelecaoSanitizacao(this)"></td>
    <td><div class="cand-row"><div class="cand-av">${iniciais(s.nome)}</div>
      <div><div class="cand-nome">${abrirCandidatoLink(s)}</div>
        <div class="cand-tel">${escapeHtml(rotuloLocal(s) === '—' ? '' : rotuloLocal(s))}${s.status_banco === 'inativo' ? ' · inativo' : ''}</div></div></div></td>
    <td>${escapeHtml(sug || '—')}</td>
    <td class="san-motivo">${escapeHtml(s.motivo_texto)}</td>
    <td><span class="pill ${cls}" title="${s.pontos} ponto(s)">${lbl}</span></td>
    <td>${fmtData(s.ultima_movimentacao)}<div class="cand-tel">${tempoRelativo(s.ultima_movimentacao)}</div></td>
    <td class="td-acoes">
      <button class="btn-sm" onclick="decidirSugestao('${s.id}','manter')" title="Manter no banco e não sugerir de novo por um tempo"><i class="ti ti-shield-check"></i>Manter</button>
      <button class="btn-sm" onclick="decidirSugestao('${s.id}','inativar')" title="Tira dos disponíveis; os dados continuam guardados"><i class="ti ti-user-off"></i>Inativar</button>
      ${ehAdministrador() ? `<button class="btn-sm vermelho" onclick="decidirSugestao('${s.id}','excluir')" title="Apaga os dados pessoais definitivamente"><i class="ti ti-trash"></i></button>` : ''}
    </td></tr>`;
}

function linhaDecidida(s) {
  const [cls, lbl] = DECISAO_PILL[s.status] || ['pill-gray', s.status];
  return `<tr>
    <td><div class="cand-nome">${abrirCandidatoLink(s)}</div>
      <div class="cand-tel">${escapeHtml(s.area_sugerida || '')}</div></td>
    <td><span class="pill ${cls}">${lbl}</span></td>
    <td>${escapeHtml(s.decidido_por_nome || 'Sistema')}</td>
    <td>${fmtDataHora(s.decidido_em)}</td>
    <td class="san-motivo">${escapeHtml(s.observacao || '—')}${s.adiada_ate ? `<div class="cand-tel">não sugerir até ${fmtData(s.adiada_ate)}</div>` : ''}</td>
    <td class="san-motivo">${escapeHtml(s.motivo_texto)}</td></tr>`;
}

// ── Seleção e ações em lote ──
function atualizarBarraLote() {
  const n = selecaoSanitizacao.size;
  $('#san-bulk').style.display = n ? 'flex' : 'none';
  $('#san-bulk-txt').textContent = `${n} selecionada${n === 1 ? '' : 's'}`;
  const todas = $('#san-todas');
  if (todas) {
    const caixas = [...$$('.san-chk')];
    todas.checked = caixas.length > 0 && caixas.every(c => c.checked);
  }
}

function alternarSelecaoSanitizacao(caixa) {
  caixa.checked ? selecaoSanitizacao.add(caixa.dataset.id) : selecaoSanitizacao.delete(caixa.dataset.id);
  caixa.closest('tr').classList.toggle('linha-sel', caixa.checked);
  atualizarBarraLote();
}

function alternarTodasSanitizacao(marcar) {
  $$('.san-chk').forEach(c => { c.checked = marcar; alternarSelecaoSanitizacao(c); });
}

function limparSelecaoSanitizacao() {
  selecaoSanitizacao.clear();
  $$('.san-chk').forEach(c => { c.checked = false; c.closest('tr').classList.remove('linha-sel'); });
  atualizarBarraLote();
}

// "Aceitar todas as de prioridade alta": pega os ids no banco (não só os da página carregada)
async function selecionarPorPrioridade(prioridade) {
  const { data, error } = await db.from('vw_sanitizacao_sugestoes').select('id')
    .eq('status', 'pendente').eq('prioridade', prioridade).limit(500);
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  if (!data.length) { toast(`Nenhuma sugestão de prioridade ${PRIORIDADE_PILL[prioridade][1].toLowerCase()} pendente`); return; }
  data.forEach(s => selecaoSanitizacao.add(s.id));
  $$('.san-chk').forEach(c => { c.checked = selecaoSanitizacao.has(c.dataset.id); c.closest('tr').classList.toggle('linha-sel', c.checked); });
  atualizarBarraLote();
  toast(`${data.length} sugestões de prioridade ${PRIORIDADE_PILL[prioridade][1].toLowerCase()} selecionadas — escolha a ação`);
}

// ── Decisão: nada é executado sem esta confirmação ──
const TEXTOS_DECISAO = {
  manter:   { titulo: 'Manter no banco', icone: 'ti-shield-check', rotulo: 'Manter',
    msg: n => `Manter ${n} candidato${n > 1 ? 's' : ''} no Banco de Talentos?\n\nEle${n > 1 ? 's' : ''} não volta${n > 1 ? 'm' : ''} a ser sugerido${n > 1 ? 's' : ''} pelo período escolhido abaixo.` },
  inativar: { titulo: 'Inativar', icone: 'ti-user-off', rotulo: 'Inativar',
    msg: n => `Inativar ${n} candidato${n > 1 ? 's' : ''}?\n\nSaem da lista de disponíveis para atribuição, mas os dados continuam guardados e podem ser reativados no Banco de Talentos.` },
  excluir:  { titulo: 'Excluir definitivamente', icone: 'ti-trash', rotulo: 'Excluir definitivamente',
    msg: n => `EXCLUIR DEFINITIVAMENTE ${n} candidato${n > 1 ? 's' : ''}?\n\nNome, contatos, currículo e análises são apagados e NÃO podem ser recuperados. Sobram só números para as métricas e a identificação de um reenvio futuro.` }
};

function decidirSugestao(id, decisao) { abrirModalDecisao([id], decisao); }

function decidirLote(decisao) {
  if (!selecaoSanitizacao.size) { toast('Selecione as sugestões primeiro', 'erro'); return; }
  abrirModalDecisao([...selecaoSanitizacao], decisao);
}

function abrirModalDecisao(ids, decisao) {
  if (decisao === 'excluir' && !ehAdministrador()) { toast('Somente o administrador pode excluir definitivamente', 'erro'); return; }
  decisaoSanitizacao = { ids, decisao };
  const t = TEXTOS_DECISAO[decisao];
  $('#san-m-titulo').textContent = t.titulo;
  $('#san-m-icone').className = 'ti ' + t.icone;
  $('#san-m-msg').textContent = t.msg(ids.length);
  $('#san-m-obs').value = '';
  $('#san-m-meses-wrap').style.display = decisao === 'manter' ? 'block' : 'none';
  const sel = $('#san-m-meses');
  if (![...sel.options].some(o => Number(o.value) === mesesPadraoAdiar)) sel.add(new Option(`${mesesPadraoAdiar} meses`, mesesPadraoAdiar));
  sel.value = String(mesesPadraoAdiar);
  $('#san-m-confirma').checked = false;
  $('#san-m-confirma-wrap').style.display = decisao === 'excluir' ? 'flex' : 'none';
  const ok = $('#san-m-ok');
  ok.textContent = ids.length > 1 ? `${t.rotulo} (${ids.length})` : t.rotulo;
  ok.classList.toggle('btn-perigo', decisao === 'excluir');
  abrirModal('modal-sanitizar');
}

async function confirmarDecisaoSanitizacao() {
  const { ids, decisao } = decisaoSanitizacao || {};
  if (!ids?.length) return;
  if (decisao === 'excluir' && !$('#san-m-confirma').checked) { toast('Marque a confirmação para excluir', 'erro'); return; }

  const obs = $('#san-m-obs').value.trim() || null;
  const meses = decisao === 'manter' ? Number($('#san-m-meses').value) : null;
  const btn = $('#san-m-ok');
  btn.disabled = true;

  let falhas = [];
  let feitas = 0;
  if (ids.length === 1) {
    const { error } = await db.rpc('sanitizacao_decidir', {
      p_sugestao_id: ids[0], p_decisao: decisao, p_observacao: obs, p_adiar_meses: meses });
    if (error) falhas = [mensagemErro(error)]; else feitas = 1;
  } else {
    const { data, error } = await db.rpc('sanitizacao_decidir_lote', {
      p_sugestao_ids: ids, p_decisao: decisao, p_observacao: obs, p_adiar_meses: meses });
    if (error) falhas = [mensagemErro(error)];
    else { feitas = data.processadas; falhas = data.falhas.map(f => f.erro); }
  }
  btn.disabled = false;

  fecharModal('modal-sanitizar');
  ids.forEach(id => selecaoSanitizacao.delete(id));
  const verbo = { manter: 'mantido', inativar: 'inativado', excluir: 'excluído' }[decisao];
  if (falhas.length) {
    toast(`${feitas} ${verbo}${feitas === 1 ? '' : 's'}; ${falhas.length} não pôde ser aplicada: ${[...new Set(falhas)][0]}`, 'erro');
  } else {
    toast(`${feitas} candidato${feitas === 1 ? '' : 's'} ${verbo}${feitas === 1 ? '' : 's'}${decisao === 'excluir' ? '. Os arquivos saem do armazenamento na próxima execução da rotina' : ''}`);
  }
  await carregarSanitizacao();
}

// ── Gerar a lista agora (administrador) ──
async function gerarSugestoesAgora() {
  if (!ehAdministrador()) return;
  if (!await confirmar({
    titulo: 'Gerar sugestões agora', rotulo: 'Gerar', perigo: false,
    mensagem: 'Gerar a lista de sugestões de sanitização agora, sem esperar o próximo ciclo?\n\nNada é apagado nem inativado: só entram na fila os candidatos que atendem às regras de Configurações.'
  })) return;
  const btn = $('#san-btn-gerar');
  btn.disabled = true;
  const { data, error } = await db.rpc('fn_gerar_sugestoes_sanitizacao', { p_origem: 'manual', p_forcar: true });
  btn.disabled = false;
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  toast(data.total ? `${data.total} sugestões geradas` : 'Nenhum candidato novo atende às regras agora');
  await carregarSanitizacao();
}

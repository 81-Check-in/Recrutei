// ═══════════════════════════════════════════════════════════
//  VAGAS
// ═══════════════════════════════════════════════════════════

async function carregarVagas() {
  const el = $('#vagas-grid');
  loading(el);

  const { data, error } = await db.from('vw_vagas_resumo')
    .select('*').order('setor_nome');

  if (error) { erro(el, error.message); return; }

  if (!data.length) {
    vazio(el, 'ti-briefcase', 'Nenhuma vaga cadastrada',
      'Clique em "Nova vaga" para começar');
    return;
  }

  el.innerHTML = data.map(v => `
    <div class="vaga-card">
      <div class="vaga-card-top">
        <div class="vaga-icon" style="background:${v.setor_cor}1a;color:${v.setor_cor}">
          <i class="ti ${v.setor_icone}"></i>
        </div>
        <div class="vaga-actions">
          <button class="action-btn" title="Editar" onclick="abrirModalVaga('${v.id}')">
            <i class="ti ti-pencil"></i></button>
          <button class="action-btn danger" title="Encerrar" data-id="${v.id}" data-titulo="${escapeHtml(v.titulo)}" onclick="encerrarVaga(this.dataset.id, this.dataset.titulo)">
            <i class="ti ti-player-pause"></i></button>
        </div>
      </div>
      <div class="vaga-titulo">${escapeHtml(v.titulo)}</div>
      <div class="vaga-empresa">${escapeHtml(v.empresas || '—')} · ${escapeHtml(v.setor_nome)}</div>
      <div class="vaga-empresa vaga-qualificacao" title="Setor, função e nível filtram os currículos do Banco de Talentos ao selecionar CVs">${
        v.funcao_setor && v.nivel_funcao
          ? `${escapeHtml(v.funcao_setor)} · ${escapeHtml(rotuloNivel(v.nivel_funcao))}`
          : '<span style="color:var(--yellow)"><i class="ti ti-alert-triangle"></i> Defina a função e o nível (Editar)</span>'}</div>
      <div class="vaga-stats">
        <button type="button" class="vaga-stat vaga-stat-link" data-vaga="${v.id}" data-titulo="${escapeHtml(v.titulo)}"
          data-pronta="${v.funcao_setor && v.nivel_funcao ? '1' : ''}"
          onclick="abrirCandidatosDaVaga(this.dataset.vaga, this.dataset.titulo, !!this.dataset.pronta)"
          title="Currículos selecionados para esta vaga. Clique para abrir a lista completa (ver, agendar entrevista, cancelar a seleção)"><div class="vaga-stat-val">${v.total_em_aberto}</div><div class="vaga-stat-lbl">Candidatos</div></button>
        <div class="vaga-stat"><div class="vaga-stat-val">${v.total_entrevistas}</div><div class="vaga-stat-lbl">Entrevistas</div></div>
        <div class="vaga-stat" title="Currículos disponíveis no banco com o mesmo setor, função e nível desta vaga"><div class="vaga-stat-val">${v.compativeis_no_banco}</div><div class="vaga-stat-lbl">No banco</div></div>
      </div>
      <div class="vaga-footer">
        <span class="pill pill-green"><i class="ti ti-point-filled" style="font-size:10px"></i>
          Ativa · ${v.dias_aberta}d</span>
        <button class="btn-triagem" data-vaga="${v.id}" data-titulo="${escapeHtml(v.titulo)}"
          data-pronta="${v.funcao_setor && v.nivel_funcao ? '1' : ''}"
          onclick="verCandidatosDaVaga(this.dataset.vaga, this.dataset.titulo, !!this.dataset.pronta)"
          title="Os currículos do Banco de Talentos com o mesmo setor, função e nível desta vaga, da maior nota para a menor">Selecionar CVs</button>
      </div>
    </div>`).join('');
}

// "TODAS" reflete o estado das lojas: marcada só quando todas estão marcadas
function sincronizarTodasEmpresas() {
  const itens = [...$$('#vaga-empresas input[data-empresa]')];
  $('#vaga-empresas-todas').checked = itens.length > 0 && itens.every(c => c.checked);
}

async function abrirModalVaga(vagaId) {
  const ehEdicao = !!vagaId;
  $('#modal-vaga-titulo').textContent = ehEdicao ? 'Editar vaga' : 'Nova vaga';
  $('#vaga-id').value = vagaId || '';

  $('#vaga-setor').innerHTML = app.cache.setores
    .map(s => `<option value="${s.id}">${escapeHtml(s.nome)}</option>`).join('');
  $('#vaga-setor').onchange = () => preencherFuncoesDaVaga();
  $('#vaga-funcao').onchange = () => preencherNiveisDaVaga();
  preencherFuncoesDaVaga();

  $('#vaga-empresas').innerHTML = app.cache.empresas.map(e => `
    <label class="chk-empresa">
      <input type="checkbox" data-empresa value="${e.id}"> ${escapeHtml(e.sigla)}
    </label>`).join('') + `
    <label class="chk-empresa chk-todas">
      <input type="checkbox" id="vaga-empresas-todas"> TODAS
    </label>`;
  $('#vaga-empresas').onchange = ev => {
    if (ev.target.id === 'vaga-empresas-todas') {
      $$('#vaga-empresas input[data-empresa]').forEach(c => { c.checked = ev.target.checked; });
    } else {
      sincronizarTodasEmpresas();
    }
  };

  $('#vaga-titulo').value = '';
  $('#vaga-descricao').value = '';
  $('#vaga-perfil').value = '';
  $('#vaga-qtd').value = 1;
  $('#req-list').innerHTML = '';
  prepararAssistenteVaga();

  if (ehEdicao) {
    const [{ data: v }, { data: reqs }, { data: emps }] = await Promise.all([
      db.from('vagas').select('*').eq('id', vagaId).single(),
      db.from('requisitos').select('*').eq('vaga_id', vagaId).order('ordem'),
      db.from('vaga_empresas').select('empresa_id').eq('vaga_id', vagaId)
    ]);
    if (v) {
      $('#vaga-titulo').value = v.titulo || '';
      $('#vaga-descricao').value = v.descricao || '';
      $('#vaga-perfil').value = v.perfil_comportamental || '';
      $('#vaga-qtd').value = v.quantidade || 1;
      // vaga de um setor que saiu do modelo (desativado): continua aparecendo, marcado, para o RH ver e trocar
      if (!app.cache.setores.some(s => s.id === v.setor_id)) {
        const { data: antigo } = await db.from('setores').select('nome').eq('id', v.setor_id).maybeSingle();
        $('#vaga-setor').insertAdjacentHTML('beforeend',
          `<option value="${v.setor_id}">${escapeHtml(antigo?.nome || 'Setor antigo')} — setor desativado, escolha outro</option>`);
      }
      $('#vaga-setor').value = v.setor_id;
      preencherFuncoesDaVaga(v.funcao_setor, v.nivel_funcao);
    }
    (emps || []).forEach(e => {
      const c = $(`#vaga-empresas input[value="${e.empresa_id}"]`);
      if (c) c.checked = true;
    });
    sincronizarTodasEmpresas();
    (reqs || []).forEach(r => addRequisito(r.descricao, r.tipo, r.peso));
  }
  if (!$('#req-list').children.length) { addRequisito(); addRequisito(); }

  abrirModal('modal-vaga');
}

// A função depende do setor: só as do setor escolhido. Junto com o setor e o nível, é o que filtra os currículos.
function preencherFuncoesDaVaga(selecionada = '', nivel = '') {
  const setorId = $('#vaga-setor').value;
  const funcoes = app.cache.funcoes.filter(f => f.setor_id === setorId);
  $('#vaga-funcao').innerHTML = '<option value="">Selecione a função…</option>' +
    funcoes.map(f => `<option value="${escapeHtml(f.nome)}">${escapeHtml(f.nome)}</option>`).join('');
  $('#vaga-funcao').value = funcoes.some(f => f.nome === selecionada) ? selecionada : '';
  preencherNiveisDaVaga(nivel);
}

// O nível também depende da função: Jovem Aprendiz e Trainee só existem nos cargos que os aceitam
// (Logística/Auxiliar, DP/Auxiliar, RH/Auxiliar, Loja/Repositor). Nos demais: Júnior, Pleno e Sênior.
function preencherNiveisDaVaga(selecionado = $('#vaga-nivel').value) {
  const funcao = app.cache.funcoes.find(f => f.setor_id === $('#vaga-setor').value && f.nome === $('#vaga-funcao').value);
  const permitidos = app.cache.niveis.filter(n => !NIVEIS_INICIANTES.includes(n.codigo) || funcao?.aceita_iniciante);
  $('#vaga-nivel').innerHTML = '<option value="">Selecione o nível…</option>' +
    permitidos.map(n => `<option value="${n.codigo}">${escapeHtml(n.nome)}</option>`).join('');
  $('#vaga-nivel').value = permitidos.some(n => n.codigo === selecionado) ? selecionado : '';
}

function addRequisito(desc = '', tipo = 'obrigatorio', peso = 1) {
  const row = document.createElement('div');
  row.className = 'req-row';
  row.innerHTML = `
    <input class="req-input" type="text" placeholder="Ex: CNH categoria B" value="${escapeHtml(desc)}">
    <select class="req-tipo">
      <option value="obrigatorio" ${tipo==='obrigatorio'?'selected':''}>Obrigatório</option>
      <option value="desejavel"  ${tipo==='desejavel' ?'selected':''}>Desejável</option>
      <option value="diferencial" ${tipo==='diferencial'?'selected':''}>Diferencial</option>
    </select>
    <input class="req-peso" type="number" min="1" max="10" value="${peso}" title="Peso 1-10">
    <button class="req-del" onclick="this.parentElement.remove()"><i class="ti ti-trash"></i></button>`;
  $('#req-list').appendChild(row);
}

// ── Assistente de IA: rascunho de descrição, perfil e requisitos ──
// Precisa do serviço HTTP do backend (api.py, POST /vagas/rascunho): sem API_URL o botão fica desligado e o formulário
// funciona como sempre. O rascunho só preenche os campos; nada é salvo até o RH clicar em "Salvar vaga".
function prepararAssistenteVaga() {
  $('#ia-vaga-pedido').value = '';
  const disponivel = !!API_URL;
  $('#ia-vaga-btn').disabled = !disponivel;
  $('#ia-vaga-pedido').disabled = !disponivel;
  $('#ia-vaga-aviso').textContent = disponivel
    ? 'A IA escreve um rascunho da descrição, do perfil e dos requisitos; você revisa antes de salvar.'
    : 'Indisponível: o serviço de IA (API_URL, em js/nucleo.js) ainda não foi configurado. Preencha a vaga à mão.';
}

function aplicarRascunhoVaga(r) {
  $('#vaga-descricao').value = r.descricao || '';
  $('#vaga-perfil').value = r.perfil_comportamental || '';
  $('#req-list').innerHTML = '';
  (r.requisitos || []).forEach(q => addRequisito(q.descricao, q.tipo, q.peso));
  if (!$('#req-list').children.length) addRequisito();
}

async function gerarRascunhoVaga() {
  const pedido = $('#ia-vaga-pedido').value.trim();
  if (pedido.length < 10) { toast('Descreva a vaga em uma ou duas frases', 'erro'); return; }
  if (!API_URL) { toast('O serviço de IA ainda não foi configurado', 'erro'); return; }

  const jaTemTexto = $('#vaga-descricao').value.trim() || $('#vaga-perfil').value.trim() ||
    [...$$('#req-list .req-input')].some(i => i.value.trim());
  if (jaTemTexto && !await confirmar({
    titulo: 'Substituir o que já está escrito?', rotulo: 'Substituir', perigo: false,
    mensagem: 'O rascunho da IA vai substituir a descrição, o perfil comportamental e os requisitos do formulário. Você pode editar tudo antes de salvar.'
  })) return;

  const btn = $('#ia-vaga-btn');
  btn.disabled = true;
  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Escrevendo…';
  try {
    const { data: { session } } = await db.auth.getSession();
    const setor = app.cache.setores.find(x => x.id === $('#vaga-setor').value)?.nome || null;
    let resp;
    try {
      resp = await fetch(`${API_URL}/vagas/rascunho`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${session?.access_token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ pedido, titulo: $('#vaga-titulo').value.trim() || null, setor })
      });
    } catch { toast('Não consegui falar com o serviço de IA. Tente de novo em instantes', 'erro'); return; }
    if (!resp.ok) {
      const det = (await resp.json().catch(() => ({}))).detail;
      toast(typeof det === 'string' ? det : 'Não foi possível gerar o rascunho agora', 'erro');
      return;
    }
    aplicarRascunhoVaga(await resp.json());
    toast('Rascunho pronto: revise a descrição e os requisitos antes de salvar');
  } finally {
    btn.disabled = !API_URL;
    btn.innerHTML = '<i class="ti ti-wand"></i>Gerar rascunho';
  }
}

async function salvarVaga() {
  const id     = $('#vaga-id').value;
  const titulo = $('#vaga-titulo').value.trim();
  if (!titulo) { toast('Informe o título da vaga', 'erro'); return; }
  const funcao = $('#vaga-funcao').value, nivel = $('#vaga-nivel').value;
  if (!funcao || !nivel) {
    toast('Escolha a função e o nível da vaga: é com o setor, a função e o nível que o sistema seleciona os currículos', 'erro');
    return;
  }

  const payload = {
    setor_id: $('#vaga-setor').value,
    funcao_setor: funcao,
    nivel_funcao: nivel,
    titulo,
    descricao: $('#vaga-descricao').value.trim() || null,
    perfil_comportamental: $('#vaga-perfil').value.trim() || null,
    quantidade: parseInt($('#vaga-qtd').value) || 1,
    atualizado_por: app.usuario.id
  };

  let vagaId = id;
  if (id) {
    const { error } = await db.from('vagas').update(payload).eq('id', id);
    if (error) { toast(error.message, 'erro'); return; }
  } else {
    payload.criado_por = app.usuario.id;
    const { data, error } = await db.from('vagas').insert(payload).select('id').single();
    if (error) { toast(error.message, 'erro'); return; }
    vagaId = data.id;
  }

  // Empresas
  await db.from('vaga_empresas').delete().eq('vaga_id', vagaId);
  const empresas = [...$$('#vaga-empresas input[data-empresa]:checked')]
    .map(c => ({ vaga_id: vagaId, empresa_id: c.value }));
  if (empresas.length) await db.from('vaga_empresas').insert(empresas);

  // Requisitos
  await db.from('requisitos').delete().eq('vaga_id', vagaId);
  const reqs = [...$$('#req-list .req-row')].map((r, i) => ({
    vaga_id: vagaId,
    descricao: r.querySelector('.req-input').value.trim(),
    tipo: r.querySelector('.req-tipo').value,
    peso: parseInt(r.querySelector('.req-peso').value) || 1,
    ordem: i
  })).filter(r => r.descricao);
  if (reqs.length) await db.from('requisitos').insert(reqs);

  fecharModal('modal-vaga');
  toast(id ? 'Vaga atualizada' : 'Vaga criada com sucesso');
  carregarVagas();
}

async function encerrarVaga(id, titulo) {
  if (!await confirmar({
    titulo: 'Encerrar vaga', rotulo: 'Encerrar', perigo: false,
    mensagem: `Encerrar a vaga "${titulo}"?\n\nO histórico das candidaturas é preservado. Candidatos que estão em processo nela continuam até você decidir; ao encerrar cada candidatura, eles voltam ao Banco de Talentos.`
  })) return;
  const { error } = await db.from('vagas').update({
    status: 'inativo',
    deleted_at: new Date().toISOString(),
    data_encerramento: new Date().toISOString().slice(0, 10),
    atualizado_por: app.usuario.id
  }).eq('id', id);
  if (error) { toast(error.message, 'erro'); return; }
  toast('Vaga encerrada');
  carregarVagas();
}

// ── Fila de exceções (aba do Banco de Talentos: ver trocarAba()) ──
// A fila é separada em dois grupos: "falhas" (link_curriculo vazio — precisa de investigação/RH) e "portal"
// (Jobbol/Trabalha Brasil — o remetente é a plataforma, o currículo está lá; ver config.PORTAIS_DE_CURRICULO).
// Os dois usam a MESMA lista/paginação (#excecoes-lista): trocar de grupo recarrega do zero, como um filtro.
const estadoExcecoes = novoEstadoLista(50);
let grupoExcecoesAtivo = 'falhas';

const CFG_EXCECOES = {
  sem_anexo:            ['ti-mail-off','Sem currículo','yellow'],
  formato_invalido:     ['ti-file-x','Formato inválido','red'],
  arquivo_corrompido:   ['ti-file-x','Sem leitura','red'],
  ocr_falhou:           ['ti-scan','OCR falhou','red'],
  docs_privado:         ['ti-lock','Docs privado','blue'],
  nao_e_curriculo:      ['ti-file-off','Não é currículo','yellow'],
  vaga_nao_identificada:['ti-help-circle','Vaga indefinida','blue'],
  erro_processamento:   ['ti-alert-triangle','Erro','red']
};

function trocarGrupoExcecoes(grupo, el) {
  if (!el || el.classList.contains('active')) return;
  $$('#exc-subtabs .subtab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  deslizarPilula($('#exc-subtabs-pilula'), el, 'x');
  grupoExcecoesAtivo = grupo;
  carregarExcecoes();
}

function lerFiltrosExcecoes() {
  return {
    email: $('#exc-filtro-email').value.trim(),
    data: $('#exc-filtro-data').value,
    tipo: $('#exc-filtro-tipo').value
  };
}

function algumFiltroExcecaoEmUso() {
  const f = lerFiltrosExcecoes();
  return !!(f.email || f.data || f.tipo);
}

function limparFiltrosExcecoes() {
  $('#exc-filtro-email').value = '';
  $('#exc-filtro-data').value = '';
  $('#exc-filtro-tipo').value = '';
  carregarExcecoes();
}

// Preenche o <select> de tipo de erro uma única vez, com os mesmos rótulos usados nos selos da lista.
function prepararFiltroTipoExcecoes() {
  const sel = $('#exc-filtro-tipo');
  if (sel.options.length > 1) return;
  Object.entries(CFG_EXCECOES).forEach(([valor, [, lbl]]) => {
    sel.insertAdjacentHTML('beforeend', `<option value="${valor}">${escapeHtml(lbl)}</option>`);
  });
}

// Contador de cada aba (falhas/portal): SEM os filtros da tela, pra sempre mostrar o tamanho real de cada fila
// (o contador da aba não devia encolher só porque um filtro de busca está ativo). Atualiza também o selo
// da aba "Fila de exceções" (soma dos dois grupos).
async function atualizarContadoresGrupoExcecoes() {
  const base = () => db.from('excecoes').select('id', { count: 'exact', head: true }).eq('status', 'pendente');
  const [falhas, portal] = await Promise.all([base().is('link_curriculo', null), base().not('link_curriculo', 'is', null)]);
  const nFalhas = falhas.count ?? 0, nPortal = portal.count ?? 0;
  $('#count-exc-falhas').textContent = nFalhas;
  $('#count-exc-portal').textContent = nPortal;
  $('#count-exc').textContent = nFalhas + nPortal;
}

function maisExcecoes() {
  const btn = $('#excecoes-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoExcecoes.limite += estadoExcecoes.tamanhoPagina;
  carregarExcecoes();
}

// Aviso de plataforma de vagas (Jobbol, Trabalha Brasil): o currículo está no portal e o e-mail traz o endereço dele
// (backend/sql/039). O endereço vem de um e-mail de terceiros: só http/https vira botão, e abre em outra aba sem dar acesso a esta.
const linkWebSeguro = u => /^https?:\/\/\S+$/i.test(u || '') ? u : '';
function abrirLinkExterno(url) {
  if (!linkWebSeguro(url)) return;
  window.open(url, '_blank', 'noopener,noreferrer');
}

// Início e fim do dia (hora local do navegador) de uma data "AAAA-MM-DD" de <input type=date>, em ISO/UTC para a consulta.
function limitesDoDia(dataStr) {
  const [ano, mes, dia] = dataStr.split('-').map(Number);
  return [new Date(ano, mes - 1, dia, 0, 0, 0).toISOString(), new Date(ano, mes - 1, dia, 23, 59, 59, 999).toISOString()];
}

async function carregarExcecoes() {
  const el = $('#excecoes-lista');
  prepararFiltroTipoExcecoes();
  const f = lerFiltrosExcecoes();
  $('#exc-btn-limpar').style.display = algumFiltroExcecaoEmUso() ? '' : 'none';
  paginaInicialSeFiltroMudou(estadoExcecoes, JSON.stringify([grupoExcecoesAtivo, f.email, f.data, f.tipo]));

  const montar = () => {
    let q = db.from('excecoes').select('*', { count: 'exact' }).eq('status', 'pendente');
    q = grupoExcecoesAtivo === 'portal' ? q.not('link_curriculo', 'is', null) : q.is('link_curriculo', null);
    if (f.email) q = q.ilike('email_remetente', `%${f.email}%`);
    if (f.data) { const [ini, fim] = limitesDoDia(f.data); q = q.gte('recebido_em', ini).lte('recebido_em', fim); }
    if (f.tipo) q = q.eq('tipo', f.tipo);
    return q.order('recebido_em', { ascending: false });
  };

  const resultado = await carregarLista(el, estadoExcecoes, montar,
    { icone: 'ti-circle-check',
      msg: algumFiltroExcecaoEmUso() ? 'Nenhuma exceção com esses filtros' : 'Nenhuma exceção pendente',
      sub: algumFiltroExcecaoEmUso() ? 'Tente ajustar ou limpar os filtros' : 'Tudo que chegou foi processado com sucesso' });

  if (!resultado) { destravarBotaoMais($('#excecoes-mais')); return; }   // erro() já foi desenhado

  atualizarPaginacao($('#excecoes-mais'), estadoExcecoes, $('#excecoes-contador'), ' pendentes');
  if (!resultado.data.length) return;
  const { data } = resultado;

  el.innerHTML = data.map(e => {
    const [ic, lbl, cor] = CFG_EXCECOES[e.tipo] || ['ti-alert-triangle', e.tipo, 'gray'];
    // Reprocessamento já pedido: mostra o selo em vez do botão, pra não pedir duas vezes
    // (a rotina do backend limpa reprocessar_solicitado_em quando termina a tentativa).
    const botaoReprocessar = e.reprocessar_solicitado_em
      ? `<span class="pill pill-blue" title="Pedido ${tempoRelativo(e.reprocessar_solicitado_em)} — a rotina tenta na próxima execução">
           <i class="ti ti-clock"></i>Reprocessamento pedido</span>`
      : `<button class="btn-sm" onclick="reprocessarExcecao('${e.id}', this)" title="Busca o e-mail original de novo e tenta classificar/avaliar mais uma vez">
           <i class="ti ti-refresh"></i>Reprocessar</button>`;
    // Com o link do currículo na plataforma, o botão é "Abrir currículo" (no lugar de Ver e-mail e Reprocessar, que não resolveriam nada):
    // o RH abre o portal, baixa o currículo e o envia por "Enviar currículo". Revisar/Ignorar continuam: são o que tira o aviso da fila.
    const link = linkWebSeguro(e.link_curriculo);
    const botoesDeLeitura = link
      ? `<button class="btn-sm verde" data-url="${escapeHtml(link)}" onclick="abrirLinkExterno(this.dataset.url)"
           title="Abre o currículo na plataforma (pode pedir login). Baixe-o e envie por Enviar currículo">
           <i class="ti ti-external-link"></i>Abrir currículo</button>`
      : `<button class="btn-sm" onclick="verEmailExcecao('${e.id}')" title="Ver o e-mail original">
           <i class="ti ti-mail"></i>Ver e-mail</button>
         ${botaoReprocessar}`;
    // "Anexo de laudo/pagamento/golpe..." (backend/pipeline.py, _detalhe_nao_curriculo): a IA reconheceu o que o anexo é. Destaca em vermelho.
    const avisoAnexo = e.tipo === 'nao_e_curriculo' && /^Anexo de /.test(e.detalhe_erro || '');
    return `<div class="exc-full${avisoAnexo ? ' exc-alerta' : ''}">
      <div class="exc-icon-box pill-${avisoAnexo ? 'red' : cor}"><i class="ti ${avisoAnexo ? 'ti-alert-octagon' : ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${avisoAnexo ? '<strong>Atenção:</strong> ' : ''}${escapeHtml(e.detalhe_erro || lbl)}</div>
      </div>
      <span class="pill pill-${avisoAnexo ? 'red' : cor}">${avisoAnexo ? 'Atenção: anexo' : lbl}</span>
      <div class="exc-btns">
        ${botoesDeLeitura}
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','revisado')">Revisar</button>
        <button class="btn-sm" onclick="resolverExcecao('${e.id}','ignorado')">Ignorar</button>
      </div>
    </div>`;
  }).join('');
}

// Escapa primeiro, SEMPRE — só depois marca URLs como link. Nessa ordem, o texto
// capturado pelo regex nunca contém aspas cruas (já viraram &quot;), então não tem
// como "fechar" o atributo href e injetar outra coisa na tag — mesmo que o e-mail
// (conteúdo de terceiros, não confiável) tente. Ver teste em xss2.js desta sessão.
function linkificar(textoEscapado) {
  return textoEscapado.replace(/https?:\/\/[^\s<]+/g,
    url => `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
}

async function verEmailExcecao(id) {
  const { data, error } = await db.from('excecoes')
    .select('email_remetente,email_assunto,email_corpo,texto_extraido,recebido_em')
    .eq('id', id).single();
  if (error) { toast(error.message, 'erro'); return; }

  $('#ve-remetente').textContent = data.email_remetente || '—';
  $('#ve-assunto').textContent = data.email_assunto || '(sem assunto)';
  $('#ve-data').textContent = fmtDataHora(data.recebido_em);

  const temCorpo = (data.email_corpo || '').trim();
  const temTexto = (data.texto_extraido || '').trim();
  $('#ve-corpo').innerHTML = temCorpo ? linkificar(escapeHtml(data.email_corpo)) : '<span class="sem-dados">Corpo vazio</span>';
  $('#ve-sec-texto').style.display = temTexto ? 'block' : 'none';
  if (temTexto) $('#ve-texto').innerHTML = linkificar(escapeHtml(data.texto_extraido));
  $('#ve-vazio').style.display = (!temCorpo && !temTexto) ? 'block' : 'none';

  abrirModal('modal-ver-email');
}

async function resolverExcecao(id, status) {
  const { error } = await db.from('excecoes').update({
    status, revisado_em: new Date().toISOString(), revisado_por: app.usuario.id
  }).eq('id', id);
  if (error) { toast(error.message, 'erro'); return; }
  toast(status === 'revisado' ? 'Marcado como revisado' : 'Item ignorado');
  carregarExcecoes();
  atualizarContadoresGrupoExcecoes();
}

// Só marca o pedido — quem busca o e-mail de novo e tenta classificar/avaliar é o
// pipeline Python (backend/pipeline.py, reprocessar_excecoes()), na próxima execução
// (diária, ou python main.py --reprocessar-excecoes). Precisa de backend/sql/017_
// reprocessar_excecoes.sql já aplicado — sem isso a coluna não existe e o PostgREST
// devolve PGRST204 (confirmado direto na API; NÃO é 42703, que é o código do Postgres
// puro — o PostgREST tem sua própria tabela de códigos).
async function reprocessarExcecao(id, btn) {
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Pedindo…'; }
  const { error } = await db.from('excecoes').update({
    reprocessar_solicitado_em: new Date().toISOString(), reprocessar_solicitado_por: app.usuario.id
  }).eq('id', id);
  if (error) {
    toast(error.code === 'PGRST204' || /schema cache/.test(error.message)
      ? 'Reprocessar ainda não habilitado no banco. Rode backend/sql/017_reprocessar_excecoes.sql.'
      : error.message, 'erro');
    if (btn) { btn.disabled = false; btn.innerHTML = '<i class="ti ti-refresh"></i>Reprocessar'; }
    return;
  }
  toast('Reprocessamento pedido — a rotina tenta na próxima execução');
  carregarExcecoes();
}

// Mesma ideia do reprocessarExcecao(), mas em massa: marca todas as pendentes que
// ainda não têm pedido em aberto (pra não reiniciar a contagem de quem já está na fila).
async function reprocessarTudo() {
  // Conta de novo (não usa estadoExcecoes.total): a lista na tela pode estar filtrada por grupo/e-mail/data/tipo,
  // mas este botão pede reprocessamento de TODAS as pendentes do banco, filtro nenhum.
  const { count } = await db.from('excecoes').select('id', { count: 'exact', head: true }).eq('status', 'pendente');
  if (!count) return;
  if (!await confirmar({
    titulo: 'Reprocessar tudo', rotulo: 'Reprocessar', perigo: false,
    mensagem: `Pedir reprocessamento de todas as exceções pendentes (${count})?\n\nA rotina tenta cada uma na próxima execução.`
  })) return;

  const btn = $('#btn-reprocessar-tudo');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Pedindo…'; }

  const { error } = await db.from('excecoes').update({
    reprocessar_solicitado_em: new Date().toISOString(), reprocessar_solicitado_por: app.usuario.id
  }).eq('status', 'pendente').is('reprocessar_solicitado_em', null);

  if (btn) { btn.disabled = false; btn.innerHTML = '<i class="ti ti-refresh"></i>Reprocessar tudo'; }

  if (error) {
    toast(error.code === 'PGRST204' || /schema cache/.test(error.message)
      ? 'Reprocessar ainda não habilitado no banco. Rode backend/sql/017_reprocessar_excecoes.sql.'
      : error.message, 'erro');
    return;
  }
  toast('Reprocessamento pedido para todas as exceções pendentes');
  carregarExcecoes();
}

// ── Upload manual de currículo ──
// Para currículo recebido fora do e-mail (WhatsApp, indicação, entrega em mão). O currículo entra no
// Banco de Talentos como qualquer outro; a vaga é OPCIONAL (se escolhida, o candidato já é atribuído a ela).
// O modal sobe o arquivo pro Storage e grava a fila (backend/sql/019_uploads_manuais.sql + 021).
// Com API_URL configurada (nucleo.js), chama backend/api.py na hora — a IA analisa e a resposta já volta com
// o resultado. Sem API_URL (ou se o serviço estiver fora do ar), fica na fila normal, processado na
// próxima execução do pipeline Python (backend/pipeline.py, processar_uploads_manuais()).
const FORMATOS_UPLOAD_MANUAL = {
  'application/pdf': '.pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/msword': '.doc'
};
const TAMANHO_MAXIMO_UPLOAD_MANUAL = 10 * 1024 * 1024;   // mesmo limite do backend (config.TAMANHO_MAXIMO_ANEXO)

async function abrirModalUploadManual() {
  $('#up-arquivo').value = '';
  $('#up-vaga').innerHTML = '<option value="">Carregando vagas…</option>';
  abrirModal('modal-upload-manual');

  const { data, error } = await db.from('vw_vagas_resumo').select('id,titulo,setor_nome').order('titulo');
  $('#up-vaga').innerHTML = '<option value="">— Só Banco de Talentos (sem vaga) —</option>' +
    (error ? '' : data.map(v => `<option value="${v.id}">${escapeHtml(rotuloVaga(v))}</option>`).join(''));

  carregarUploadsManuais();
}

// Envia 1 ou vários arquivos escolhidos de uma vez (input multiple). Um só: mostra o toast de cada etapa,
// igual sempre foi. Vários: processa em sequência (o serviço da IA já avalia 1 por vez, backend/api.py) e só
// mostra um toast-resumo no final; o detalhe de cada um (inclusive erro de análise) fica em "Últimos envios".
async function enviarUploadManual() {
  const vagaId = $('#up-vaga').value;
  const arquivos = [...$('#up-arquivo').files];
  if (!arquivos.length) { toast('Escolha um arquivo', 'erro'); return; }

  const validos = [];
  let semFormato = 0, semTamanho = 0;
  for (const arquivo of arquivos) {
    if (!FORMATOS_UPLOAD_MANUAL[arquivo.type]) { semFormato++; continue; }
    if (arquivo.size > TAMANHO_MAXIMO_UPLOAD_MANUAL) { semTamanho++; continue; }
    validos.push(arquivo);
  }
  if (!validos.length) {
    toast(semFormato ? 'Formato não aceito — envie PDF, DOC ou DOCX' : 'Arquivo maior que 10 MB', 'erro');
    return;
  }

  const btn = $('#up-btn-enviar');
  btn.disabled = true;
  const lote = validos.length > 1;
  let registrados = 0;

  for (let i = 0; i < validos.length; i++) {
    const progresso = lote ? ` ${i + 1} de ${validos.length}` : '';
    btn.innerHTML = `<i class="ti ti-loader-2 girando"></i>Enviando${progresso}…`;
    const resultado = await enviarUmCurriculoManual(validos[i], vagaId, btn, progresso);
    if (resultado.registrado) registrados++;
    if (!lote) toast(resultado.mensagem, resultado.tipo);
  }

  $('#up-arquivo').value = '';
  btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para o banco';

  if (lote) {
    const ignorados = semFormato + semTamanho;
    const partes = [`${registrados} de ${validos.length} currículos enviados`];
    if (ignorados) partes.push(`${ignorados} ignorado${ignorados > 1 ? 's' : ''} (formato ou tamanho)`);
    toast(partes.join(' — '), registrados ? 'ok' : 'erro');
  }

  carregarUploadsManuais();
  if (registrados && app.telaAtual === 'banco') { opcoesBancoCarregadas = false; carregarBanco(); }
}

// Sobe 1 arquivo pro Storage, grava a fila e, com API_URL, já pede a análise da IA na hora.
// `registrado` = true assim que o arquivo está gravado na fila (mesmo que a análise em si falhe depois —
// nesse caso ele continua na fila para a rotina agendada tentar de novo, e some no card "Últimos envios").
async function enviarUmCurriculoManual(arquivo, vagaId, btn, progresso) {
  const ext = FORMATOS_UPLOAD_MANUAL[arquivo.type];
  const caminho = `manual/${new Date().getFullYear()}/${crypto.randomUUID()}${ext}`;
  const { error: erroUpload } = await db.storage.from('curriculos')
    .upload(caminho, arquivo, { contentType: arquivo.type, upsert: false });
  if (erroUpload) return { registrado: false, tipo: 'erro', mensagem: erroUpload.message };

  const { data: registro, error } = await db.from('uploads_manuais').insert({
    vaga_id: vagaId || null,
    nome_arquivo: arquivo.name,
    tipo_mime: arquivo.type,
    tamanho_bytes: arquivo.size,
    storage_path: caminho,
    enviado_por: app.usuario.id
  }).select('id').single();

  if (error) {
    return { registrado: false, tipo: 'erro', mensagem: error.code === 'PGRST205' || /schema cache/.test(error.message)
      ? 'Envio manual ainda não habilitado no banco. Rode backend/sql/019_uploads_manuais.sql.'
      : error.message };
  }

  if (!API_URL) return { registrado: true, tipo: 'ok', mensagem: 'Currículo enviado — a IA analisa na próxima execução da rotina' };

  btn.innerHTML = `<i class="ti ti-loader-2 girando"></i>Analisando${progresso}…`;
  const resultado = await avaliarUploadAgora(registro.id);
  return { ...resultado, registrado: true };
}

// Chama backend/api.py pra analisar na hora. Se o serviço estiver fora do ar (ou
// API_URL não configurada), o currículo já está gravado na fila — a rotina agendada
// processa depois, então aqui só avisamos que vai demorar mais, sem tratar como erro.
async function avaliarUploadAgora(uploadId) {
  const { data: { session } } = await db.auth.getSession();
  if (!session) return { tipo: 'ok', mensagem: 'Currículo enviado — a IA analisa na próxima execução da rotina' };

  let resp;
  try {
    resp = await fetch(`${API_URL}/uploads-manuais/${uploadId}/avaliar`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${session.access_token}` }
    });
  } catch {
    return { tipo: 'erro', mensagem: 'Currículo enviado — análise imediata indisponível agora, entra na fila normal' };
  }

  if (!resp.ok) {
    const det = (await resp.json().catch(() => ({}))).detail;
    return { tipo: 'erro', mensagem: resp.status === 503 && typeof det === 'string'      // 503 = IA pausada na Zona de perigo: o currículo espera na fila
      ? `Currículo enviado — ${det}. Ele fica na fila e é analisado quando a pausa acabar`
      : 'Currículo enviado — análise imediata falhou, entra na fila normal' };
  }

  const resultado = await resp.json();
  if (resultado.status === 'erro') {
    return { tipo: 'erro', mensagem: resultado.detalhe_erro || 'Não foi possível analisar este currículo' };
  }
  if (resultado.status === 'processado' && resultado.candidato_gerado_id) {
    const { data: c } = await db.from('vw_banco_talentos')
      .select('nome,area_sugerida,cargo_sugerido,nivel_sugerido').eq('id', resultado.candidato_gerado_id).maybeSingle();
    const sugestao = c ? [c.area_sugerida, c.cargo_sugerido, rotuloNivel(c.nivel_sugerido)].filter(Boolean).join(' / ') : '';
    const aviso = resultado.detalhe_erro ? ` (${resultado.detalhe_erro})` : '';
    return { tipo: resultado.detalhe_erro ? 'erro' : 'ok',
      mensagem: `${c?.nome || 'Candidato'} entrou no Banco de Talentos${sugestao ? ' — ' + sugestao : ''}${aviso}` };
  }
  return { tipo: 'ok', mensagem: 'Currículo enviado — a IA analisa na próxima execução da rotina' };
}

async function carregarUploadsManuais() {
  const el = $('#up-lista');
  el.innerHTML = '<p class="sem-dados">Carregando…</p>';

  const { data, error } = await db.from('uploads_manuais')
    .select('id,nome_arquivo,status,detalhe_erro,enviado_em,vagas(titulo)')
    .gte('enviado_em', new Date(Date.now() - 60 * 60 * 1000).toISOString())      // só a última hora
    .order('enviado_em', { ascending: false }).limit(5);

  if (error) { el.innerHTML = ''; return; }   // tabela pode não existir ainda — não trava o modal
  if (!data.length) { el.innerHTML = '<p class="sem-dados">Nenhum envio na última hora</p>'; return; }

  const CFG = {
    pendente:   ['ti-clock', 'Pendente', 'yellow'],
    processado: ['ti-circle-check', 'Processado', 'green'],
    erro:       ['ti-alert-triangle', 'Falhou', 'red']
  };
  el.innerHTML = data.map(u => {
    const [ic, lbl, cor] = CFG[u.status] || ['ti-file', u.status, 'gray'];
    const detalhe = u.detalhe_erro ? ' · ' + escapeHtml(u.detalhe_erro) : '';
    return `<div class="exc-full" style="padding:10px 12px">
      <div class="exc-icon-box pill-${cor}"><i class="ti ${ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(u.nome_arquivo)}</div>
        <div class="exc-meta">${escapeHtml((u.vagas || {}).titulo || 'Só Banco de Talentos')} · ${tempoRelativo(u.enviado_em)}${detalhe}</div>
      </div>
      <span class="pill pill-${cor}"><i class="ti ${ic}"></i>${lbl}</span>
    </div>`;
  }).join('');
}

// Clicar no menu "Banco de Talentos" sempre volta para a aba "Currículos" (não fica preso na Fila de
// exceções de uma visita anterior). Só troca de verdade se estava na outra aba: evita recarregar à toa.
function resetarAbaBanco() {
  const tab = $$('.tab')[0];
  if (!tab || tab.classList.contains('active')) return;
  $$('.tab').forEach(t => t.classList.remove('active'));
  tab.classList.add('active');
  $$('.sub-screen').forEach(s => s.classList.remove('active'));
  $('#sub-banco').classList.add('active');
  $('#btn-reprocessar-tudo').style.display = 'none';
}

// Abas do Banco de Talentos: "banco" (currículos) e "excecoes" (e-mails que não puderam ser processados)
function trocarAba(aba, el) {
  $$('.tab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  deslizarPilula($('#tabs-pilula'), el, 'x');
  $$('.sub-screen').forEach(s => s.classList.remove('active'));
  $('#sub-' + aba).classList.add('active');
  $('#btn-reprocessar-tudo').style.display = aba === 'excecoes' ? 'flex' : 'none';
  if (aba === 'excecoes') {
    // As sub-abas (falhas/portal) ficaram ocultas até agora: a pílula precisa da largura real, só disponível depois de aparecer.
    const subaba = $('#exc-subtabs .subtab.active');
    if (subaba) deslizarPilula($('#exc-subtabs-pilula'), subaba, 'x', false);
    carregarExcecoes();
    atualizarContadoresGrupoExcecoes();
  } else carregarBanco();
}



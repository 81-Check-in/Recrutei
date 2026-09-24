// ═══════════════════════════════════════════════════════════
//  VAGAS
// ═══════════════════════════════════════════════════════════

async function carregarVagas() {
  const el = $('#vagas-grid');
  loading(el);

  const { data, error } = await db.from('vw_vagas_resumo')
    .select('*').order('setor_nome');

  if (error) { erro(el, error.message); return; }

  $('#count-vagas').textContent = data.length;

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

// ── Fila de exceções ──
const estadoExcecoes = novoEstadoLista(50);

function maisExcecoes() {
  const btn = $('#excecoes-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoExcecoes.limite += estadoExcecoes.tamanhoPagina;
  carregarExcecoes();
}

async function carregarExcecoes() {
  const el = $('#excecoes-lista');

  const montar = () => db.from('excecoes').select('*', { count: 'exact' })
    .eq('status', 'pendente').order('recebido_em', { ascending: false });

  const resultado = await carregarLista(el, estadoExcecoes, montar,
    { icone: 'ti-circle-check', msg: 'Nenhuma exceção pendente',
      sub: 'Tudo que chegou foi processado com sucesso' });

  if (!resultado) { destravarBotaoMais($('#excecoes-mais')); return; }   // erro() já foi desenhado

  $('#count-exc').textContent = estadoExcecoes.total;
  atualizarPaginacao($('#excecoes-mais'), estadoExcecoes, $('#excecoes-contador'), ' pendentes');
  if (!resultado.data.length) return;
  const { data } = resultado;

  const CFG = {
    sem_anexo:            ['ti-mail-off','Sem currículo','yellow'],
    formato_invalido:     ['ti-file-x','Formato inválido','red'],
    arquivo_corrompido:   ['ti-file-x','Sem leitura','red'],
    ocr_falhou:           ['ti-scan','OCR falhou','red'],
    docs_privado:         ['ti-lock','Docs privado','blue'],
    nao_e_curriculo:      ['ti-file-off','Não é currículo','yellow'],
    vaga_nao_identificada:['ti-help-circle','Vaga indefinida','blue'],
    erro_processamento:   ['ti-alert-triangle','Erro','red']
  };

  el.innerHTML = data.map(e => {
    const [ic, lbl, cor] = CFG[e.tipo] || ['ti-alert-triangle', e.tipo, 'gray'];
    // Reprocessamento já pedido: mostra o selo em vez do botão, pra não pedir duas vezes
    // (a rotina do backend limpa reprocessar_solicitado_em quando termina a tentativa).
    const botaoReprocessar = e.reprocessar_solicitado_em
      ? `<span class="pill pill-blue" title="Pedido ${tempoRelativo(e.reprocessar_solicitado_em)} — a rotina tenta na próxima execução">
           <i class="ti ti-clock"></i>Reprocessamento pedido</span>`
      : `<button class="btn-sm" onclick="reprocessarExcecao('${e.id}', this)" title="Busca o e-mail original de novo e tenta classificar/avaliar mais uma vez">
           <i class="ti ti-refresh"></i>Reprocessar</button>`;
    return `<div class="exc-full">
      <div class="exc-icon-box pill-${cor}"><i class="ti ${ic}"></i></div>
      <div class="exc-info">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${escapeHtml(e.detalhe_erro || lbl)}</div>
      </div>
      <span class="pill pill-${cor}">${lbl}</span>
      <div class="exc-btns">
        <button class="btn-sm" onclick="verEmailExcecao('${e.id}')" title="Ver o e-mail original">
          <i class="ti ti-mail"></i>Ver e-mail</button>
        ${botaoReprocessar}
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
  if (!estadoExcecoes.total) return;
  if (!await confirmar({
    titulo: 'Reprocessar tudo', rotulo: 'Reprocessar', perigo: false,
    mensagem: `Pedir reprocessamento de todas as exceções pendentes (${estadoExcecoes.total})?\n\nA rotina tenta cada uma na próxima execução.`
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

async function enviarUploadManual() {
  const vagaId = $('#up-vaga').value;
  const arquivo = $('#up-arquivo').files[0];
  if (!arquivo) { toast('Escolha um arquivo', 'erro'); return; }
  const ext = FORMATOS_UPLOAD_MANUAL[arquivo.type];
  if (!ext) { toast('Formato não aceito — envie PDF, DOC ou DOCX', 'erro'); return; }
  if (arquivo.size > TAMANHO_MAXIMO_UPLOAD_MANUAL) { toast('Arquivo maior que 10 MB', 'erro'); return; }

  const btn = $('#up-btn-enviar');
  btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Enviando…';

  const caminho = `manual/${new Date().getFullYear()}/${crypto.randomUUID()}${ext}`;
  const { error: erroUpload } = await db.storage.from('curriculos')
    .upload(caminho, arquivo, { contentType: arquivo.type, upsert: false });

  if (erroUpload) {
    toast(erroUpload.message, 'erro');
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para o banco';
    return;
  }

  const { data: registro, error } = await db.from('uploads_manuais').insert({
    vaga_id: vagaId || null,
    nome_arquivo: arquivo.name,
    tipo_mime: arquivo.type,
    tamanho_bytes: arquivo.size,
    storage_path: caminho,
    enviado_por: app.usuario.id
  }).select('id').single();

  if (error) {
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para o banco';
    toast(error.code === 'PGRST205' || /schema cache/.test(error.message)
      ? 'Envio manual ainda não habilitado no banco. Rode backend/sql/019_uploads_manuais.sql.'
      : error.message, 'erro');
    return;
  }

  $('#up-arquivo').value = '';

  if (!API_URL) {
    btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para o banco';
    toast('Currículo enviado — a IA analisa na próxima execução da rotina');
    carregarUploadsManuais();
    return;
  }

  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Analisando…';
  await avaliarUploadAgora(registro.id);
  btn.disabled = false; btn.innerHTML = '<i class="ti ti-send"></i>Enviar para o banco';
  carregarUploadsManuais();
  if (app.telaAtual === 'banco') { opcoesBancoCarregadas = false; carregarBanco(); }
}

// Chama backend/api.py pra analisar na hora. Se o serviço estiver fora do ar (ou
// API_URL não configurada), o currículo já está gravado na fila — a rotina agendada
// processa depois, então aqui só avisamos que vai demorar mais, sem tratar como erro.
async function avaliarUploadAgora(uploadId) {
  const { data: { session } } = await db.auth.getSession();
  if (!session) { toast('Currículo enviado — a IA analisa na próxima execução da rotina'); return; }

  let resp;
  try {
    resp = await fetch(`${API_URL}/uploads-manuais/${uploadId}/avaliar`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${session.access_token}` }
    });
  } catch {
    toast('Currículo enviado — análise imediata indisponível agora, entra na fila normal');
    return;
  }

  if (!resp.ok) {
    toast('Currículo enviado — análise imediata falhou, entra na fila normal', 'erro');
    return;
  }

  const resultado = await resp.json();
  if (resultado.status === 'erro') {
    toast(resultado.detalhe_erro || 'Não foi possível analisar este currículo', 'erro');
    return;
  }
  if (resultado.status === 'processado' && resultado.candidato_gerado_id) {
    const { data: c } = await db.from('vw_banco_talentos')
      .select('nome,area_sugerida,cargo_sugerido,nivel_sugerido').eq('id', resultado.candidato_gerado_id).maybeSingle();
    const sugestao = c ? [c.area_sugerida, c.cargo_sugerido, rotuloNivel(c.nivel_sugerido)].filter(Boolean).join(' / ') : '';
    const aviso = resultado.detalhe_erro ? ` (${resultado.detalhe_erro})` : '';
    toast(`${c?.nome || 'Candidato'} entrou no Banco de Talentos${sugestao ? ' — ' + sugestao : ''}${aviso}`,
          resultado.detalhe_erro ? 'erro' : 'ok');
    return;
  }
  toast('Currículo enviado — a IA analisa na próxima execução da rotina');
}

async function carregarUploadsManuais() {
  const el = $('#up-lista');
  el.innerHTML = '<p class="sem-dados">Carregando…</p>';

  const { data, error } = await db.from('uploads_manuais')
    .select('id,nome_arquivo,status,detalhe_erro,enviado_em,vagas(titulo)')
    .order('enviado_em', { ascending: false }).limit(8);

  if (error) { el.innerHTML = ''; return; }   // tabela pode não existir ainda — não trava o modal
  if (!data.length) { el.innerHTML = '<p class="sem-dados">Nenhum envio ainda</p>'; return; }

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

function trocarAba(aba, el) {
  $$('.tab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
  deslizarPilula($('#tabs-pilula'), el, 'x');
  $$('.sub-screen').forEach(s => s.classList.remove('active'));
  $('#sub-' + aba).classList.add('active');
  $('#btn-reprocessar-tudo').style.display = aba === 'excecoes' ? 'flex' : 'none';
  if (aba === 'excecoes') carregarExcecoes();
  else carregarVagas();
}



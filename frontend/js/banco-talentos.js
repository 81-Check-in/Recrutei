// ═══════════════════════════════════════════════════════════
//  BANCO DE TALENTOS
//  Todo currículo cai aqui primeiro, independente de vaga. O RH escolhe o candidato e o atribui,
//  à mão, a uma vaga aberta; se ele for reprovado, volta para cá (o banco faz isso sozinho).
//  As gravações passam por funções do banco (atribuir_candidato_vaga, editar_candidato, …): o painel
//  não escreve direto em "candidatos" (ver backend/sql/022).
// ═══════════════════════════════════════════════════════════

const estadoBanco = novoEstadoLista(50);

// Filtros avançados: null = nenhum. Os de TEXTO (palavras no currículo, endereço, rotatividade) vão para a
// função filtrar_banco_talentos(); os demais são colunas com índice e entram como filtro normal.
let filtrosAvancados = null;
let opcoesBancoCarregadas = false;

function alternarFiltrosAvancados() {
  const painel = $('#painel-filtros-av');
  const abrir = painel.style.display === 'none';
  painel.style.display = abrir ? 'block' : 'none';
  $('#btn-filtros-av').setAttribute('aria-expanded', String(abrir));
}

// Só entra no objeto o que a pessoa preencheu. `texto` alimenta a função do banco; `colunas`, os filtros normais.
function lerFiltrosAvancados() {
  const texto = {}, colunas = {};
  let ativos = 0;

  const palavras = $('#av-palavras').value.split(',').map(p => p.trim()).filter(Boolean);
  if (palavras.length) {
    texto.palavras = palavras;
    texto.palavras_modo = $('#av-palavras-modo').value;
    texto.palavras_onde = $('#av-palavras-onde').value;
    ativos++;
  }
  const local = $('#av-local').value.trim();
  if (local) { texto.local = local; ativos++; }
  const excluirLocais = $('#av-excluir-locais').value.split(',').map(p => p.trim()).filter(Boolean);
  if (excluirLocais.length) { texto.excluir_locais = excluirLocais; ativos++; }
  const rotatividade = $('#av-rotatividade').value;
  if (rotatividade) { texto.rotatividade = rotatividade; ativos++; }

  const idadeMin = $('#av-idade-min').value.trim();
  const idadeMax = $('#av-idade-max').value.trim();
  if (idadeMin) { colunas.idade_min = Number(idadeMin); ativos++; }
  if (idadeMax) { colunas.idade_max = Number(idadeMax); ativos++; }
  const escolaridade = $('#av-escolaridade').value;
  if (escolaridade) { colunas.escolaridade_min = escolaridade; ativos++; }
  const experiencia = $('#av-experiencia').value.trim();
  if (experiencia) { colunas.experiencia_min = Number(experiencia); ativos++; }
  if ($('#av-cnh').checked) { colunas.cnh = true; ativos++; }
  if ($('#av-revisao').checked) { colunas.revisao = true; ativos++; }
  colunas.incluir_sem_info = $('#av-sem-info').checked;
  if (!colunas.incluir_sem_info) ativos++;                 // o padrão é incluir

  return { texto, colunas, ativos };
}

function atualizarBadgeFiltrosAv(ativos) {
  const badge = $('#badge-filtros-av');
  badge.style.display = ativos ? 'inline-flex' : 'none';
  badge.textContent = ativos;
  $('#btn-filtros-av').classList.toggle('ativo', ativos > 0);
}

// Guarda o que está nos campos avançados como filtro ativo (sem recarregar a lista)
function guardarFiltrosAvancados() {
  const { texto, colunas, ativos } = lerFiltrosAvancados();
  filtrosAvancados = ativos ? { texto: Object.keys(texto).length ? texto : null, colunas } : null;
  atualizarBadgeFiltrosAv(ativos);
  return ativos;
}

function aplicarFiltrosAvancados() {
  const ativos = guardarFiltrosAvancados();
  toast(ativos ? `${ativos} filtro${ativos > 1 ? 's' : ''} aplicado${ativos > 1 ? 's' : ''}` : 'Nenhum filtro preenchido');
  return carregarBanco();
}

function limparCamposAvancados() {
  ['av-palavras', 'av-local', 'av-excluir-locais', 'av-idade-min', 'av-idade-max', 'av-experiencia']
    .forEach(id => { $('#' + id).value = ''; });
  $('#av-palavras-modo').value = 'todas';
  $('#av-palavras-onde').value = 'curriculo';
  $('#av-escolaridade').value = '';
  $('#av-rotatividade').value = '';
  $('#av-cnh').checked = false;
  $('#av-revisao').checked = false;
  $('#av-sem-info').checked = true;
  filtrosAvancados = null;
  atualizarBadgeFiltrosAv(0);
}

function limparFiltrosAvancados() {
  limparCamposAvancados();
  return carregarBanco();
}

// Volta a lista ao ponto de partida (disponíveis, sem busca nem filtro) sem recarregar
function limparTodosFiltrosBanco() {
  ['#busca-banco', '#filtro-b-cidade', '#filtro-b-area', '#filtro-b-cargo', '#filtro-b-nivel', '#filtro-b-sexo']
    .forEach(s => { $(s).value = ''; });
  $('#filtro-b-status').value = 'ativo';
  $('#ordem-banco').value = 'entrada';
  limparCamposAvancados();
}

// ── Consulta ──
const ESCOLARIDADE_ORD = { nenhuma: 0, fundamental: 1, medio: 2, tecnico: 3, superior: 4, pos: 5 };
const dataIso = d => d.toISOString().slice(0, 10);

// Quem tem N anos nasceu em (hoje − N anos) ou antes. Filtrar pela data de nascimento (indexada) em vez de
// calcular a idade linha a linha é o que deixa a busca por faixa etária rápida.
function nascimentoParaIdade(anos) {
  const d = new Date();
  d.setFullYear(d.getFullYear() - anos);
  return d;
}

// Filtro numérico que, com "incluir quem não informou", também deixa passar o campo vazio
function comSemInfo(q, coluna, condicoes, incluirSemInfo) {
  if (!condicoes.length) return q;
  if (!incluirSemInfo) return condicoes.reduce((acc, c) => acc.filter(coluna, c[0], c[1]), q);
  const e = condicoes.map(c => `${coluna}.${c[0]}.${c[1]}`);
  return q.or(`${coluna}.is.null,${e.length > 1 ? `and(${e.join(',')})` : e[0]}`);
}

function aplicarColunasAvancadas(q, c) {
  const sem = c.incluir_sem_info;
  const idade = [];
  if (c.idade_min != null) idade.push(['lte', dataIso(nascimentoParaIdade(c.idade_min))]);
  if (c.idade_max != null) {
    const d = nascimentoParaIdade(c.idade_max + 1);
    d.setDate(d.getDate() + 1);                             // idade ≤ máx  ⇔  nascido depois de (hoje − máx−1 anos)
    idade.push(['gte', dataIso(d)]);
  }
  q = comSemInfo(q, 'nascimento_ref', idade, sem);
  if (c.escolaridade_min) q = comSemInfo(q, 'escolaridade_ord', [['gte', ESCOLARIDADE_ORD[c.escolaridade_min]]], sem);
  if (c.experiencia_min != null) q = comSemInfo(q, 'anos_experiencia', [['gte', c.experiencia_min]], sem);
  if (c.cnh) q = q.not('cnh', 'is', null);
  if (c.revisao) q = q.eq('revisao_manual', true);
  return q;
}

function montarConsultaBanco() {
  const nome    = normBusca($('#busca-banco').value.trim());
  const cidade  = normBusca($('#filtro-b-cidade').value.trim());
  const area    = $('#filtro-b-area').value;
  const cargo   = $('#filtro-b-cargo').value;
  const nivel   = $('#filtro-b-nivel').value;
  const sexo    = $('#filtro-b-sexo').value;
  const status  = $('#filtro-b-status').value;
  const ordem   = $('#ordem-banco').value;

  // Com filtro de texto a busca parte da função do banco; ela devolve as mesmas colunas da view,
  // então os filtros comuns encaixam do mesmo jeito por cima.
  let q = filtrosAvancados?.texto
    ? db.rpc('filtrar_banco_talentos', { filtros: filtrosAvancados.texto }, { count: 'exact' })
    : db.from('vw_banco_talentos').select('*', { count: 'exact' });

  if (nome)   q = q.like('nome_norm', `%${escaparLike(nome)}%`);       // parcial; índice trigrama
  if (cidade) q = q.like('cidade_norm', `${escaparLike(cidade)}%`);    // prefixo; índice (cidade_norm, …)
  if (area)   q = q.eq('area_sugerida', area);
  if (cargo)  q = q.eq('cargo_sugerido', cargo);
  if (nivel)  q = q.eq('nivel_sugerido', nivel);
  if (sexo)   q = sexo === 'nao_informado' ? q.is('sexo', null) : q.eq('sexo', sexo);
  if (status) q = q.eq('status_banco', status);
  if (filtrosAvancados) q = aplicarColunasAvancadas(q, filtrosAvancados.colunas);

  if (ordem === 'nome')              q = q.order('nome_norm', { ascending: true });
  else if (ordem === 'movimentacao') q = q.order('ultima_movimentacao', { ascending: true });
  else                               q = q.order('data_entrada', { ascending: false });
  return q.order('id');                                                // desempate estável na paginação
}

// Áreas e cargos que a IA já sugeriu, para os filtros (a IA pode sugerir uma área fora da lista de setores)
async function carregarOpcoesBanco(forcar = false) {
  if (opcoesBancoCarregadas && !forcar) return;
  const { data, error } = await db.from('vw_banco_opcoes').select('tipo,valor,total');
  if (error) return;
  const monta = (id, tipo, todos, extras = []) => {
    const sel = $(id), atual = sel.value;
    const valores = new Map();
    extras.forEach(v => valores.set(v, 0));
    (data || []).filter(o => o.tipo === tipo).forEach(o => valores.set(o.valor, o.total));
    const itens = [...valores.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'pt-BR'));
    sel.innerHTML = `<option value="">${todos}</option>` +
      itens.map(([v, n]) => `<option value="${escapeHtml(v)}">${escapeHtml(v)}${n ? ` (${n})` : ''}</option>`).join('');
    if ([...valores.keys()].includes(atual)) sel.value = atual;
  };
  monta('#filtro-b-area', 'area', 'Todas as áreas', app.cache.setores.map(s => s.nome));
  monta('#filtro-b-cargo', 'cargo', 'Todos os cargos');
  opcoesBancoCarregadas = true;
}

function maisBanco() {
  const btn = $('#banco-mais');
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Carregando…'; }
  estadoBanco.limite += estadoBanco.tamanhoPagina;
  return carregarBanco();
}

// ── Lista ──
function htmlTagsCandidato(c) {
  const t = [];
  if (c.lista_negra)
    t.push('<span class="tag-mini preto" title="Bloqueado pelo RH: não recebe vagas nem e-mails">Lista negra</span>');
  if (c.revisao_manual && !c.reanalise_solicitada_em)
    t.push('<span class="tag-mini amarelo" title="A IA não classificou com segurança: confira o currículo">Revisão manual</span>');
  if (c.reanalise_solicitada_em)
    t.push('<span class="tag-mini" title="A IA vai (re)analisar este currículo na próxima execução da rotina">IA analisando…</span>');
  if (c.sanitizacao_pendente)
    t.push('<span class="tag-mini roxo" title="Está na lista de sugestões de sanitização">Sugerido p/ limpeza</span>');
  if (c.total_reprovacoes > 0)
    t.push(`<span class="tag-mini vermelho" title="Reprovações anteriores em vagas">↺ ${c.total_reprovacoes} reprovaç${c.total_reprovacoes > 1 ? 'ões' : 'ão'}</span>`);
  return t.join(' ');
}

// Card de um candidato na lista. `extra` só existe no ranking de uma vaga: { selo, termos, meta } (HTML já escapado).
function htmlCartaoBanco(c, extra = {}) {
  const [cls, lbl] = STATUS_BANCO[c.status_banco] || ['pill-gray', c.status_banco];
  const sugestao = [c.area_sugerida, c.cargo_sugerido, rotuloNivel(c.nivel_sugerido)].filter(Boolean).join(' / ');
  const resumo = c.reanalise_solicitada_em && !c.resumo_ia
    ? 'Aguardando a análise da IA (próxima execução da rotina)' : (c.resumo_ia || 'Sem análise da IA ainda');
  const atribuir = c.status_banco === 'ativo'
    ? `<button type="button" class="btn-sm verde" onclick="event.stopPropagation();abrirAtribuicaoPorId('${c.id}')"
         title="Atribuir a uma vaga aberta"><i class="ti ti-arrow-right-circle"></i>Atribuir</button>` : '';
  return `<div class="curr-card" tabindex="0" role="button" onclick="abrirTalento('${c.id}')"
      onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();abrirTalento('${c.id}')}">
    <div class="curr-ini">${iniciais(c.nome)}</div>
    <div class="curr-info">
      <div class="curr-nome">${escapeHtml(c.nome || 'Nome não extraído')} ${htmlTagsCandidato(c)}</div>
      <div class="curr-resumo">${escapeHtml(resumo)}</div>
      <div class="curr-meta">
        ${sugestao ? `<span title="Sugestão da IA: área / cargo / nível"><i class="ti ti-sparkles"></i>${escapeHtml(sugestao)}</span>` : ''}
        ${c.cidade || c.uf ? `<span><i class="ti ti-map-pin"></i>${escapeHtml(rotuloLocal(c))}</span>` : ''}
        ${c.idade != null ? `<span><i class="ti ti-user"></i>${c.idade_estimada ? '~' : ''}${c.idade} anos</span>` : ''}
        ${c.status_banco === 'em_processo' && c.vaga_atual_titulo
          ? `<span><i class="ti ti-briefcase"></i>${escapeHtml(c.vaga_atual_titulo)}</span>` : ''}
        ${c.curriculo_recebido_em
          ? `<span title="E-mail enviado em ${fmtDataHoraCompleta(c.curriculo_recebido_em)} · entrou no banco em ${fmtData(c.data_entrada)}"><i class="ti ti-calendar"></i>Enviado ${fmtData(c.curriculo_recebido_em)}</span>`
          : `<span title="Entrou no banco em ${fmtData(c.data_entrada)}"><i class="ti ti-calendar"></i>${tempoRelativo(c.data_entrada)}</span>`}
        ${c.telefone ? `<span><i class="ti ti-phone"></i>${escapeHtml(c.telefone)}</span>` : ''}
        ${extra.meta || ''}
      </div>
      ${extra.termos || ''}
    </div>
    <div class="curr-acoes">${extra.selo || ''}${atribuir}<span class="pill ${cls}">${lbl}</span></div>
  </div>`;
}

async function carregarBanco() {
  if (rankingVaga) return carregarRankingVaga();
  atualizarModoRanking();
  const el = $('#banco-lista');
  carregarOpcoesBanco();

  const chave = JSON.stringify(['b', $('#busca-banco').value, $('#filtro-b-cidade').value, $('#filtro-b-area').value,
    $('#filtro-b-cargo').value, $('#filtro-b-nivel').value, $('#filtro-b-sexo').value, $('#filtro-b-status').value,
    $('#ordem-banco').value, filtrosAvancados]);
  paginaInicialSeFiltroMudou(estadoBanco, chave);

  const resultado = await carregarLista(el, estadoBanco, montarConsultaBanco,
    { icone: 'ti-users-group', msg: 'Nenhum candidato encontrado',
      sub: 'Os currículos entram aqui assim que a rotina processa os e-mails ou você envia um pelo painel',
      mensagemErro });

  if (!resultado) { destravarBotaoMais($('#banco-mais')); return; }     // erro() já foi desenhado

  atualizarPaginacao($('#banco-mais'), estadoBanco, $('#banco-total'), ' candidatos');
  if (!resultado.data.length) return;

  el.innerHTML = resultado.data.map(c => htmlCartaoBanco(c)).join('');
}

// Atalhos de outras telas: partem de uma lista limpa (uma busca antiga esquecida não pode esconder os candidatos)
// e a tela carrega uma vez só, já com o filtro.
// ═══════════════════════════════════════════════════════════
//  SELEÇÃO DE CVs POR VAGA  (Vagas → "Selecionar CVs")
//  Os currículos disponíveis do Banco de Talentos com EXATAMENTE o setor, a função e o nível da vaga (a qualificação que a
//  IA gravou em cada currículo), da maior nota para a menor. Sem IA: é um filtro SQL. Quem foi reprovado/descartado nesta
//  vaga, está na lista negra ou já está em processo não aparece. A conta está em selecionar_curriculos_vaga()
//  (backend/sql/033); o painel só a chama e desenha.
// ═══════════════════════════════════════════════════════════
let rankingVaga = null;            // { id, titulo } enquanto o Banco mostra o ranking de uma vaga

function mudarFiltroRanking() {
  estadoBanco.limite = estadoBanco.tamanhoPagina;
  return carregarBanco();
}

function verCandidatosDaVaga(vagaId, titulo, pronta = true) {
  // sem função e nível a vaga não filtra nada: leva o RH direto ao formulário para preencher
  if (!pronta) {
    toast('Defina a função e o nível da vaga para selecionar currículos', 'erro');
    abrirModalVaga(vagaId);
    return;
  }
  rankingVaga = { id: vagaId, titulo };
  $('#rk-ordem').value = 'nota';
  $('#rk-km').value = '';
  estadoBanco.limite = estadoBanco.tamanhoPagina;
  irPara('banco');
}

// Volta ao Banco de Talentos normal (recarrega a lista, salvo quando quem chama vai recarregar por conta própria)
function sairDoRanking(recarregar = true) {
  rankingVaga = null;
  atualizarModoRanking();
  estadoBanco.limite = estadoBanco.tamanhoPagina;
  if (recarregar) carregarBanco();
}

function atualizarModoRanking() {
  const ativo = !!rankingVaga;
  $('#banco-ranking').style.display = ativo ? 'flex' : 'none';
  $('#banco-filtros').style.display = ativo ? 'none' : '';
  if (ativo) $('#painel-filtros-av').style.display = 'none';
  $('#ordem-banco').style.display = ativo ? 'none' : '';
  if (!ativo) return;
  $('#banco-ranking-titulo').textContent = rankingVaga.titulo || 'vaga';
}

const classeNotaCv = n => n == null ? 'baixa' : n >= 75 ? 'alta' : n >= 50 ? 'media' : 'baixa';

async function carregarRankingVaga() {
  const el = $('#banco-lista');
  atualizarModoRanking();
  if (estadoBanco.limite === estadoBanco.tamanhoPagina) loading(el);
  const versao = ++estadoBanco.versao;

  const km = $('#rk-km').value;
  const { data: ranking, error } = await db.rpc('selecionar_curriculos_vaga', {
    p_vaga_id: rankingVaga.id, p_limite: estadoBanco.limite, p_deslocamento: 0,
    p_ordem: $('#rk-ordem').value, p_km_max: km ? Number(km) : null });
  if (versao !== estadoBanco.versao) return;               // trocou de tela ou de vaga enquanto esperava
  if (error) { erro(el, mensagemErro(error)); destravarBotaoMais($('#banco-mais')); return; }

  estadoBanco.total = ranking[0]?.total ?? 0;
  if (!ranking.length) {
    vazio(el, 'ti-target-arrow', 'Nenhum currículo com o setor, a função e o nível desta vaga',
      km ? 'Nenhum candidato mora até essa distância da loja mais próxima. Quem não tem região identificada fica de fora quando há limite de distância'
         : 'Só aparecem currículos já qualificados pela IA com exatamente esse setor, função e nível. Quem foi reprovado nesta vaga não volta a ela');
    atualizarPaginacao($('#banco-mais'), estadoBanco, $('#banco-total'), ' currículos');
    return;
  }

  const ids = ranking.map(r => r.candidato_id);
  const { data: cartoes, error: erroCartoes } = await db.from('vw_banco_talentos').select('*').in('id', ids);
  if (versao !== estadoBanco.versao) return;
  if (erroCartoes) { erro(el, mensagemErro(erroCartoes)); return; }
  const porId = new Map((cartoes || []).map(c => [c.id, c]));

  atualizarPaginacao($('#banco-mais'), estadoBanco, $('#banco-total'), ' currículos');
  el.innerHTML = ranking.map((r, i) => {
    const c = porId.get(r.candidato_id);
    if (!c) return '';
    const termos = '';
    const selo = `<div class="aderencia ${classeNotaCv(r.nota)}" title="${r.nota == null ? 'Currículo sem nota' : `Nota de classificação do currículo (nº ${i + 1} da lista)`}">
        <b>${r.nota ?? '—'}</b><i style="width:${r.nota ?? 0}%"></i></div>`;
    const meta = r.km_mais_proxima != null
      ? `<span title="Distância em linha reta até a loja mais próxima da vaga (estimativa)"><i class="ti ti-route"></i>${formatarKm(r.km_mais_proxima)} da ${escapeHtml(r.loja_mais_proxima)}</span>`
      : `<span class="sem-dados" title="Sem região identificada não dá para estimar a distância. Informe em Editar dados"><i class="ti ti-route"></i>região não identificada</span>`;
    return htmlCartaoBanco(c, { selo, termos, meta });
  }).join('');
}


function irBancoRevisao() {
  rankingVaga = null;                 // atalho do dashboard: o banco normal, não o ranking de uma vaga
  limparTodosFiltrosBanco();
  $('#av-revisao').checked = true;
  guardarFiltrosAvancados();
  irPara('banco');
}

// ═══════════════════════════════════════════════════════════
//  SUGESTÃO DA IA (usada no drawer e na tela de atribuição)
// ═══════════════════════════════════════════════════════════
function htmlSugestaoIA(c) {
  const chip = (rotulo, valor) =>
    `<div class="ia-chip"><span>${rotulo}</span><strong>${valor ? escapeHtml(valor) : '—'}</strong></div>`;
  const conf = c.ia_confianca;
  const classeConf = conf == null ? '' : conf >= 75 ? 'alta' : conf >= 50 ? 'media' : 'baixa';
  let aviso = '';
  if (c.reanalise_solicitada_em) {
    aviso = `<div class="ia-alerta info"><i class="ti ti-clock"></i>
      <div>A IA vai (re)analisar este currículo na próxima execução da rotina.</div></div>`;
  }
  if (c.revisao_manual) {
    aviso += `<div class="ia-alerta"><i class="ti ti-eye-check"></i>
      <div><strong>Revisão manual necessária.</strong> ${escapeHtml(c.motivo_revisao || 'A IA não classificou com segurança.')}
      Confira o currículo antes de decidir.</div></div>`;
  }
  return `<div class="ia-chips">${chip('Área', c.area_sugerida)}${chip('Cargo', c.cargo_sugerido)}${chip('Nível', rotuloNivel(c.nivel_sugerido))}</div>
    ${conf != null ? `<div class="conf ${classeConf}"><div class="conf-lbl">Confiança da IA <b>${conf}%</b></div>
      <div class="conf-barra"><i style="width:${conf}%"></i></div></div>` : ''}${aviso}`;
}

// ── Região e distância até as lojas (backend/sql/030) ──
const ORIGEM_REGIAO = { manual: 'definida pelo RH', ia: 'identificada pela IA', texto: 'pelo endereço do currículo', cidade: 'pela cidade' };
const formatarKm = km => `${Number(km).toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} km`;
// Só para dar uma ideia rápida; o número exato está ao lado. É linha reta entre os centros das regiões (estimativa).
const faixaDeDistancia = km => km <= 8 ? ['perto', 'Perto'] : km <= 20 ? ['medio', 'Médio'] : ['longe', 'Longe'];

const htmlTags = (lista, classe, vazio) => (lista || []).length
  ? lista.map(t => `<span class="tag ${classe}">${escapeHtml(t)}</span>`).join('')
  : `<span class="sem-dados">${vazio}</span>`;

// ═══════════════════════════════════════════════════════════
//  DRAWER DO CANDIDATO
// ═══════════════════════════════════════════════════════════
const STATUS_CANDIDATURA = {
  aguardando:          ['pill-yellow', 'Aguardando entrevista'],
  selecionado:         ['pill-yellow', 'Aguardando entrevista'],
  entrevista_agendada: ['pill-blue',   'Entrevista agendada'],
  entrevista_realizada:['pill-blue',   'Entrevistado'],
  aprovado:            ['pill-green',  'Aprovado'],
  reprovado:           ['pill-red',    'Reprovado'],
  nao_compareceu:      ['pill-purple', 'Não compareceu'],
  contratado:          ['pill-green',  'Contratado'],
  cancelado:           ['pill-gray',   'Cancelada'],
  descartado:          ['pill-gray',   'Descartado']
};

async function abrirTalento(id) {
  const [{ data: c, error }, { data: hist }] = await Promise.all([
    db.from('vw_banco_talentos').select('*').eq('id', id).single(),
    db.from('vw_candidaturas')
      .select('id,vaga_titulo,setor_nome,status,origem,nota,recebido_em,data_atribuicao,encerrada_em,resultado_final,atribuido_por_nome')
      .eq('candidato_id', id).order('recebido_em', { ascending: false })
  ]);
  if (error) { toast('Erro ao carregar candidato: ' + mensagemErro(error), 'erro'); return; }
  app.talentoAberto = c;
  desenharTalento(c, hist || []);
  $('#drawer-talento').classList.add('show');
  $('#drawer-overlay').classList.add('show');
}

function desenharTalento(c, hist) {
  const [clsSt, lblSt] = STATUS_BANCO[c.status_banco] || ['pill-gray', c.status_banco];
  $('#t-nome').textContent = c.nome || 'Nome não extraído';
  $('#t-sub').innerHTML = `<span class="pill ${clsSt}">${lblSt}</span> · entrou ${tempoRelativo(c.data_entrada)}` +
    (c.status_banco === 'em_processo' && c.vaga_atual_titulo ? ` · ${escapeHtml(c.vaga_atual_titulo)}` : '');

  $('#t-ia').innerHTML = `<div class="ia-box-tit"><i class="ti ti-sparkles"></i>Sugestão da IA</div>${htmlSugestaoIA(c)}
    <div class="ia-rodape"><span>${c.data_analise ? `Analisado ${tempoRelativo(c.data_analise)}${c.versao_modelo_ia ? ' · ' + escapeHtml(c.versao_modelo_ia) : ''}` : 'Ainda sem análise'}</span>
      <button type="button" class="btn-sm" id="t-btn-reanalisar" onclick="reanalisarCandidato()"
        title="Refaz a análise da IA a partir do currículo atual"><i class="ti ti-refresh"></i>Reanalisar</button></div>`;

  const sexo = c.sexo === 'masculino' ? 'Masculino' : c.sexo === 'feminino' ? 'Feminino' : '—';
  const escolaridade = { nenhuma: 'Sem escolaridade', fundamental: 'Fundamental', medio: 'Médio', tecnico: 'Técnico',
                         superior: 'Superior', pos: 'Pós-graduação' }[c.escolaridade] || '—';
  const dado = (rotulo, valor) =>
    `<div class="dado"><div class="dado-lbl">${rotulo}</div><div class="dado-val">${escapeHtml(valor || '—')}</div></div>`;
  $('#t-dados').innerHTML =
    dado('Telefone', c.telefone) + dado('E-mail', c.email) +
    // vêm do cabeçalho do e-mail (não da IA): existem mesmo que o currículo não traga e-mail ou a análise falhe
    dado('E-mail de envio (de quem mandou)', c.curriculo_email_envio) +
    dado('E-mail enviado em', c.curriculo_recebido_em ? fmtDataHoraCompleta(c.curriculo_recebido_em) : '') +
    dado('Mora em', rotuloLocal(c) === '—' ? '' : rotuloLocal(c)) +
    dado('Região (distância até as lojas)', c.regiao_nome ? `${c.regiao_nome} — ${ORIGEM_REGIAO[c.regiao_origem] || 'identificada'}` : 'Não identificada') +
    dado('Idade', c.idade != null ? `${c.idade_estimada ? '~' : ''}${c.idade} anos` : '') + dado('Sexo', sexo) +
    dado('Escolaridade', escolaridade) +
    dado('Experiência', c.anos_experiencia != null ? `${c.anos_experiencia} ano${Number(c.anos_experiencia) === 1 ? '' : 's'}` : '') +
    dado('CNH', c.cnh) +
    dado('Último contato', c.ultimo_contato_em ? fmtDataHora(c.ultimo_contato_em) : '') +
    dado('Consentimento (LGPD)', c.consentimento_em ? `Registrado em ${fmtData(c.consentimento_em)}` : 'Não registrado');

  $('#t-positivos').innerHTML = htmlTags(c.pontos_positivos, 'verde', 'Nenhum ponto positivo registrado');
  $('#t-negativos').innerHTML = htmlTags(c.pontos_negativos, 'vermelha', 'Nenhum ponto negativo registrado');
  $('#t-resumo').textContent = c.resumo_ia || 'Resumo ainda não gerado pela IA.';

  $('#t-historico').innerHTML = hist.length ? hist.map(h => {
    const [cls, lbl] = STATUS_CANDIDATURA[h.status] || ['pill-gray', h.status];
    const legado = h.origem === 'triagem_legada';
    const quando = fmtData(h.data_atribuicao || h.recebido_em);
    return `<div class="hist-item${legado ? ' legado' : ''}">
      <div class="hist-topo"><strong>${escapeHtml(h.vaga_titulo || 'Vaga removida')}</strong>
        <span class="pill ${cls}">${lbl}</span></div>
      <div class="hist-meta">${legado ? 'Vínculo automático da triagem anterior' : `Atribuído em ${quando}${h.atribuido_por_nome ? ' por ' + escapeHtml(h.atribuido_por_nome) : ''}`}
        ${h.nota != null ? ` · nota ${h.nota}` : ''}${h.encerrada_em ? ` · encerrada em ${fmtData(h.encerrada_em)}` : ''}</div>
      ${h.resultado_final && !legado ? `<div class="hist-res">${escapeHtml(h.resultado_final)}</div>` : ''}
    </div>`;
  }).join('') : '<span class="sem-dados">Nunca foi atribuído a uma vaga</span>';

  mostrarConsideracoes('t', c.id);
  const ativo = c.status_banco === 'ativo';
  $('#t-btn-atribuir').style.display = ativo ? 'flex' : 'none';
  const st = $('#t-btn-status');
  st.style.display = ['ativo', 'inativo'].includes(c.status_banco) && !c.lista_negra ? 'flex' : 'none';   // reativar não vale na lista negra

  const negra = $('#t-negra');
  negra.style.display = c.lista_negra ? 'flex' : 'none';
  negra.innerHTML = c.lista_negra
    ? `<i class="ti ti-ban"></i><div><strong>Na lista negra</strong>${c.lista_negra_motivo ? ` — ${escapeHtml(c.lista_negra_motivo)}` : ''}
       <div class="aviso-negra-meta">${c.lista_negra_por_nome ? `por ${escapeHtml(c.lista_negra_por_nome)} · ` : ''}${c.lista_negra_em ? fmtData(c.lista_negra_em) : ''}
       · não recebe vagas nem e-mails</div></div>` : '';
  $('#t-btn-negra').style.display = c.lista_negra || c.status_banco === 'expurgado' ? 'none' : 'flex';
  $('#t-btn-liberar').style.display = c.lista_negra ? 'flex' : 'none';
  st.innerHTML = c.status_banco === 'inativo'
    ? '<i class="ti ti-user-check"></i>Reativar' : '<i class="ti ti-user-off"></i>Inativar';
  $('#t-btn-excluir').style.display = ehAdministrador() ? 'flex' : 'none';
  $('#t-btn-curriculo').style.display = c.storage_path ? 'flex' : 'none';
  $('#t-btn-baixar').style.display = c.storage_path ? 'flex' : 'none';
  $('#t-sem-arquivo').style.display = c.storage_path ? 'none' : 'flex';
}

function fecharDrawer() {
  $('#drawer').classList.remove('show');
  $('#drawer-talento').classList.remove('show');
  $('#drawer-overlay').classList.remove('show');
}

async function recarregarTalento() {
  if (!app.talentoAberto) return;
  const aberto = $('#drawer-talento').classList.contains('show');
  if (aberto) await abrirTalento(app.talentoAberto.id);
  if (app.telaAtual === 'banco') carregarBanco();
}

// ── Currículo original (URL assinada) ──
async function urlDoCurriculo(storagePath) {
  const { data, error } = await db.storage.from('curriculos').createSignedUrl(storagePath, 3600);
  if (error) { toast('Erro ao abrir currículo: ' + error.message, 'erro'); return null; }
  return data.signedUrl;
}

async function curriculoDoCandidato(candidatoId) {
  const { data } = await db.from('curriculos').select('storage_path,nome_arquivo')
    .eq('candidato_id', candidatoId).eq('atual', true).maybeSingle();
  if (!data?.storage_path) { toast('Arquivo do currículo não disponível', 'erro'); return null; }
  return data;
}

async function verCurriculoDoCandidato(candidatoId) {
  const id = candidatoId || app.talentoAberto?.id;
  if (!id) return;
  const cv = await curriculoDoCandidato(id);
  const url = cv && await urlDoCurriculo(cv.storage_path);
  if (url) window.open(url, '_blank');
}

async function baixarCurriculoDoCandidato(candidatoId) {
  const id = candidatoId || app.talentoAberto?.id;
  if (!id) return;
  const cv = await curriculoDoCandidato(id);
  if (!cv) return;
  const { data, error } = await db.storage.from('curriculos').download(cv.storage_path);
  if (error) { toast('Erro ao baixar: ' + error.message, 'erro'); return; }
  const url = URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url;
  a.download = cv.nome_arquivo || 'curriculo.pdf';
  a.click();
  URL.revokeObjectURL(url);
}

// ── Reanálise da IA: na hora (se o serviço web estiver no ar) ou pedida à rotina ──
async function reanalisarCandidato() {
  const c = app.talentoAberto;
  if (!c) return;
  const btn = $('#t-btn-reanalisar');
  btn.disabled = true;
  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i>Analisando…';

  const pedirARotina = async () => {
    const { error } = await db.rpc('solicitar_reanalise', { p_candidato_id: c.id });
    if (error) { toast(mensagemErro(error), 'erro'); return false; }
    toast('Reanálise pedida — a IA analisa na próxima execução da rotina');
    return true;
  };

  try {
    if (!API_URL) { await pedirARotina(); return; }
    const { data: { session } } = await db.auth.getSession();
    let resp;
    try {
      resp = await fetch(`${API_URL}/candidatos/${c.id}/analisar`, {
        method: 'POST', headers: { Authorization: `Bearer ${session?.access_token}` } });
    } catch { await pedirARotina(); return; }       // serviço fora do ar: cai na fila normal
    if (!resp.ok) {
      const det = (await resp.json().catch(() => ({}))).detail;
      toast(det || 'Não foi possível analisar agora', 'erro');
      await db.rpc('solicitar_reanalise', { p_candidato_id: c.id });   // a rotina tenta depois
      return;
    }
    const r = await resp.json();
    toast(`Analisado: ${[r.area_sugerida, r.cargo_sugerido, rotuloNivel(r.nivel_sugerido)].filter(Boolean).join(' / ') || 'sem classificação'}`);
    opcoesBancoCarregadas = false;
  } finally {
    await recarregarTalento();
  }
}

// ═══════════════════════════════════════════════════════════
//  ATRIBUIÇÃO MANUAL A UMA VAGA
//  Lado a lado: sugestão da IA (Área / Cargo / Nível) e os dados da vaga. É só apoio: a decisão é do RH.
// ═══════════════════════════════════════════════════════════
let vagasAtribuicao = [];          // vagas abertas (vw_vagas_resumo)
const detalheVagaCache = {};       // id → { requisitos, perfil }

async function abrirAtribuicaoPorId(id) {
  const { data: c, error } = await db.from('vw_banco_talentos').select('*').eq('id', id).single();
  if (error) { toast('Erro ao carregar candidato: ' + mensagemErro(error), 'erro'); return; }
  app.talentoAberto = c;
  await abrirAtribuicao();
}

async function abrirAtribuicao() {
  const c = app.talentoAberto;
  if (!c) return;
  if (c.status_banco !== 'ativo') { toast('Só candidatos disponíveis podem ser atribuídos a uma vaga', 'erro'); return; }

  $('#atr-obs').value = '';
  $('#atr-candidato').innerHTML = `
    <div class="atr-nome">${escapeHtml(c.nome || 'Nome não extraído')}</div>
    <div class="atr-local">${escapeHtml(rotuloLocal(c) === '—' ? '' : rotuloLocal(c))}${c.idade != null ? ` · ${c.idade_estimada ? '~' : ''}${c.idade} anos` : ''}</div>
    ${htmlSugestaoIA(c)}
    <div class="drawer-sec-tit" style="margin-top:14px">Pontos positivos</div>
    <div class="tags">${htmlTags((c.pontos_positivos || []).slice(0, 4), 'verde', 'Nenhum registrado')}</div>
    <div class="drawer-sec-tit" style="margin-top:12px">Pontos negativos</div>
    <div class="tags">${htmlTags((c.pontos_negativos || []).slice(0, 4), 'vermelha', 'Nenhum registrado')}</div>
    <p class="atr-resumo">${escapeHtml(c.resumo_ia || '')}</p>`;

  $('#atr-vaga').innerHTML = '<option value="">Carregando vagas…</option>';
  $('#atr-vaga-info').innerHTML = '';
  $('#atr-compat').innerHTML = '';
  abrirModal('modal-atribuir');

  const { data, error } = await db.from('vw_vagas_resumo')
    .select('id,titulo,descricao,quantidade,dias_aberta,setor_nome,setor_cor,setor_icone,empresas,total_em_aberto').order('titulo');
  if (error || !data?.length) {
    $('#atr-vaga').innerHTML = `<option value="">${error ? 'Não foi possível carregar as vagas' : 'Nenhuma vaga aberta'}</option>`;
    return;
  }
  vagasAtribuicao = data;

  // Vagas em que ele já foi reprovado/descartado não voltam (só vagas novas): aparecem, mas bloqueadas
  const { data: barradas } = await db.from('vw_candidaturas').select('vaga_id,encerrada_em')
    .eq('candidato_id', c.id).in('status', ['reprovado', 'descartado']);
  const barradasPorVaga = new Map((barradas || []).filter(b => b.vaga_id).map(b => [b.vaga_id, b.encerrada_em]));
  const barrada = v => barradasPorVaga.has(v.id);

  // A vaga do mesmo setor da área sugerida vem primeiro (só ordenação: nada é escolhido por ela); as barradas, por último
  const casa = v => normBusca(v.setor_nome) === normBusca(c.area_sugerida);
  const ordenadas = [...data].sort((a, b) => Number(barrada(a)) - Number(barrada(b)) ||
    Number(casa(b)) - Number(casa(a)) || a.titulo.localeCompare(b.titulo, 'pt-BR'));
  $('#atr-vaga').innerHTML = '<option value="">Escolha a vaga…</option>' +
    ordenadas.map(v => barrada(v)
      ? `<option value="${v.id}" disabled>${escapeHtml(rotuloVaga(v))} — reprovado nesta vaga${barradasPorVaga.get(v.id) ? ' em ' + fmtData(barradasPorVaga.get(v.id)) : ''}</option>`
      : `<option value="${v.id}">${escapeHtml(rotuloVaga(v))}${casa(v) ? '  ★ combina com a área sugerida' : ''}</option>`).join('');

  // Veio do ranking de uma vaga: ela já vem escolhida (a decisão continua sendo do RH: é só confirmar)
  if (rankingVaga && ordenadas.some(v => v.id === rankingVaga.id && !barrada(v))) {
    $('#atr-vaga').value = rankingVaga.id;
    await mostrarVagaAtribuicao();
  }
}

async function mostrarVagaAtribuicao() {
  const id = $('#atr-vaga').value;
  const info = $('#atr-vaga-info'), compat = $('#atr-compat');
  const v = vagasAtribuicao.find(x => x.id === id);
  if (!v) { info.innerHTML = ''; compat.innerHTML = ''; $('#atr-distancias').innerHTML = ''; return; }

  if (!detalheVagaCache[id]) {
    info.innerHTML = '<p class="sem-dados">Carregando dados da vaga…</p>';
    const [{ data: reqs }, { data: vaga }] = await Promise.all([
      db.from('requisitos').select('descricao,tipo,peso').eq('vaga_id', id).order('ordem'),
      db.from('vagas').select('perfil_comportamental').eq('id', id).single()
    ]);
    detalheVagaCache[id] = { requisitos: reqs || [], perfil: vaga?.perfil_comportamental || '' };
  }
  if ($('#atr-vaga').value !== id) return;                 // trocou de vaga enquanto carregava
  const { requisitos, perfil } = detalheVagaCache[id];
  const obrig = requisitos.filter(r => r.tipo === 'obrigatorio'), desej = requisitos.filter(r => r.tipo === 'desejavel');
  const difer = requisitos.filter(r => r.tipo === 'diferencial');

  info.innerHTML = `
    <div class="vaga-det">
      <div class="vaga-det-topo"><span class="vaga-det-ico" style="background:${escapeHtml(v.setor_cor)}1a;color:${escapeHtml(v.setor_cor)}"><i class="ti ${escapeHtml(v.setor_icone)}"></i></span>
        <div><strong>${escapeHtml(v.titulo)}</strong><div class="vaga-det-sub">${escapeHtml(v.setor_nome)}${v.empresas ? ' · ' + escapeHtml(v.empresas) : ''}</div></div></div>
      <div class="vaga-det-meta">${v.quantidade} posição(ões) · aberta há ${v.dias_aberta} dia(s) · ${v.total_em_aberto} candidato(s) em processo</div>
      ${v.descricao ? `<div class="drawer-sec-tit" style="margin-top:12px">Descrição</div><p class="atr-resumo" style="margin-top:0">${escapeHtml(v.descricao)}</p>` : ''}
      ${obrig.length ? `<div class="drawer-sec-tit" style="margin-top:12px">Requisitos obrigatórios</div><div class="tags">${obrig.map(r => `<span class="tag vermelha">${escapeHtml(r.descricao)}</span>`).join('')}</div>` : ''}
      ${desej.length ? `<div class="drawer-sec-tit" style="margin-top:12px">Desejáveis</div><div class="tags">${desej.map(r => `<span class="tag verde">${escapeHtml(r.descricao)}</span>`).join('')}</div>` : ''}
      ${difer.length ? `<div class="drawer-sec-tit" style="margin-top:12px" title="Bônus: somam pontos extras e nunca eliminam">Diferenciais</div><div class="tags">${difer.map(r => `<span class="tag azul">${escapeHtml(r.descricao)}</span>`).join('')}</div>` : ''}
      ${perfil ? `<div class="drawer-sec-tit" style="margin-top:12px">Perfil comportamental</div><p class="atr-resumo" style="margin-top:0">${escapeHtml(perfil)}</p>` : ''}
    </div>`;

  // Compatibilidade: só informativa — nunca bloqueia
  const c = app.talentoAberto;
  let html;
  if (!c.area_sugerida) {
    html = '<div class="compat neutro"><i class="ti ti-help-circle"></i>A IA não sugeriu uma área para este candidato: decida pelo currículo.</div>';
  } else if (normBusca(c.area_sugerida) === normBusca(v.setor_nome)) {
    html = `<div class="compat ok"><i class="ti ti-circle-check"></i>A área sugerida pela IA (<strong>${escapeHtml(c.area_sugerida)}</strong>) é o setor desta vaga.</div>`;
  } else {
    html = `<div class="compat difere"><i class="ti ti-alert-triangle"></i>A IA sugere <strong>${escapeHtml(c.area_sugerida)}</strong> e esta vaga é de <strong>${escapeHtml(v.setor_nome)}</strong>. Você pode atribuir mesmo assim.</div>`;
  }
  compat.innerHTML = html;
  mostrarDistanciasAtribuicao(id, c);
}

// Distância do candidato até cada loja da vaga (só apoio à decisão do RH; nunca bloqueia)
async function mostrarDistanciasAtribuicao(vagaId, c) {
  const el = $('#atr-distancias');
  el.innerHTML = '';
  const { data, error } = await db.rpc('distancias_para_vaga', { p_vaga_id: vagaId, p_candidatos: [c.id] });
  if ($('#atr-vaga').value !== vagaId || error || !data?.length) return;    // trocou de vaga enquanto esperava
  const d = data[0];
  if (!d.regiao) {
    el.innerHTML = `<div class="compat neutro"><i class="ti ti-route"></i>A região onde ${escapeHtml(c.nome || 'o candidato')} mora não foi identificada.
      Informe em <strong>Editar dados</strong> para ver a distância até as lojas.</div>`;
    return;
  }
  if (!(d.lojas || []).length) {
    el.innerHTML = '<div class="compat neutro"><i class="ti ti-route"></i>As lojas desta vaga ainda não têm local cadastrado.</div>';
    return;
  }
  el.innerHTML = `<div class="dist-box">
    <div class="dist-tit"><i class="ti ti-route"></i>Distância de ${escapeHtml(d.regiao)} até as lojas da vaga <span>estimativa em linha reta</span></div>
    <div class="dist-lojas">${d.lojas.map(l => {
      const [cls, rotulo] = faixaDeDistancia(l.km);
      return `<div class="dist-loja ${cls}"><b>${escapeHtml(l.sigla)}</b><span>${escapeHtml(l.regiao || '')}</span><em>${formatarKm(l.km)}</em><i>${rotulo}</i></div>`;
    }).join('')}</div></div>`;
}

async function confirmarAtribuicao() {
  const c = app.talentoAberto;
  const vagaId = $('#atr-vaga').value;
  if (!vagaId) { toast('Escolha a vaga', 'erro'); return; }
  const v = vagasAtribuicao.find(x => x.id === vagaId);

  const btn = $('#atr-confirmar');
  btn.disabled = true;
  const { error } = await db.rpc('atribuir_candidato_vaga', {
    p_candidato_id: c.id, p_vaga_id: vagaId, p_observacao: $('#atr-obs').value.trim() || null
  });
  btn.disabled = false;

  if (error) { toast(mensagemErro(error), 'erro'); return; }
  fecharModal('modal-atribuir');
  fecharDrawer();
  toast(`${c.nome || 'Candidato'} atribuído à vaga ${v ? v.titulo : ''}. A IA avalia o currículo para esta vaga na próxima execução`);
  if (app.telaAtual === 'banco') carregarBanco();
}

// ═══════════════════════════════════════════════════════════
//  AÇÕES SOBRE O CANDIDATO
// ═══════════════════════════════════════════════════════════
async function registrarContato() {
  const c = app.talentoAberto;
  if (!c) return;
  const { error } = await db.rpc('registrar_contato_candidato', { p_candidato_id: c.id });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  toast('Contato registrado');
  await recarregarTalento();
}

async function alternarInativo() {
  const c = app.talentoAberto;
  if (!c) return;
  const inativar = c.status_banco === 'ativo';
  if (!await confirmar({
    titulo: inativar ? 'Inativar candidato' : 'Reativar candidato', rotulo: inativar ? 'Inativar' : 'Reativar',
    perigo: false,
    mensagem: inativar
      ? `Tirar ${c.nome || 'este candidato'} da lista de disponíveis?\n\nOs dados continuam guardados (ele só deixa de aparecer para atribuição). Você pode reativá-lo depois.`
      : `Voltar ${c.nome || 'este candidato'} para a lista de disponíveis?`
  })) return;
  const { error } = await db.rpc('alterar_status_banco', { p_candidato_id: c.id, p_novo: inativar ? 'inativo' : 'ativo' });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  toast(inativar ? 'Candidato inativado' : 'Candidato reativado');
  await recarregarTalento();
}

async function excluirDadosCandidato() {
  const c = app.talentoAberto;
  if (!c || !ehAdministrador()) return;
  if (!await confirmar({
    titulo: 'Excluir dados do candidato', rotulo: 'Excluir definitivamente',
    mensagem: `Apagar TODOS os dados pessoais de ${c.nome || 'este candidato'} (pedido do titular — LGPD art. 18)?\n\n` +
              'Nome, contatos, currículo e análises são apagados e não podem ser recuperados. ' +
              'Se ele estiver em um processo seletivo, a candidatura é cancelada. Sobram só números para as métricas.'
  })) return;
  const { error } = await db.rpc('excluir_dados_candidato', { p_candidato_id: c.id, p_motivo: 'Exclusão pelo painel' });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  fecharDrawer();
  toast('Dados excluídos. O arquivo do currículo sai do armazenamento na próxima execução da rotina');
  if (app.telaAtual === 'banco') carregarBanco();
}

// ── Editar dados ──
const CAMPOS_EDICAO = {
  nome: '#ed-nome', telefone: '#ed-telefone', email: '#ed-email', cidade: '#ed-cidade', uf: '#ed-uf',
  bairro: '#ed-bairro', regiao_id: '#ed-regiao',
  data_nascimento: '#ed-nascimento', sexo: '#ed-sexo', escolaridade: '#ed-escolaridade',
  anos_experiencia: '#ed-experiencia', cnh: '#ed-cnh'
};

async function carregarRegioes() {
  if (app.cache.regioes) return app.cache.regioes;
  const { data } = await db.from('regioes_df').select('id,nome,uf').order('nome');
  app.cache.regioes = data || [];
  return app.cache.regioes;
}

async function abrirEdicaoCandidato() {
  const c = app.talentoAberto;
  if (!c) return;
  const regioes = await carregarRegioes();                       // as opções precisam existir antes de escolher o valor
  $('#ed-regiao').innerHTML = '<option value="">Automática (pela cidade)</option>' +
    regioes.map(r => `<option value="${r.id}">${escapeHtml(r.nome)}${r.uf && r.uf !== 'DF' ? ' — ' + r.uf : ''}</option>`).join('');
  for (const [campo, seletor] of Object.entries(CAMPOS_EDICAO)) $(seletor).value = c[campo] ?? '';
  $('#ed-consent').textContent = c.consentimento_em
    ? `Consentimento registrado em ${fmtData(c.consentimento_em)}.`
    : 'Nenhum consentimento registrado. Sem ele, o prazo máximo no banco (Configurações) conta a partir da entrada.';
  abrirModal('modal-editar-candidato');
}

async function salvarEdicaoCandidato() {
  const c = app.talentoAberto;
  if (!c) return;
  const dados = {};
  for (const [campo, seletor] of Object.entries(CAMPOS_EDICAO)) {
    const novo = $(seletor).value.trim();
    if (novo !== String(c[campo] ?? '')) dados[campo] = novo;
  }
  if ('telefone' in dados) dados.telefone_e164 = normalizaTelefone(dados.telefone) || '';
  if (!Object.keys(dados).length) { fecharModal('modal-editar-candidato'); return; }

  const btn = $('#ed-salvar');
  btn.disabled = true;
  const { error } = await db.rpc('editar_candidato', { p_candidato_id: c.id, p_dados: dados });
  btn.disabled = false;
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  fecharModal('modal-editar-candidato');
  toast('Dados atualizados');
  await recarregarTalento();
}

async function registrarConsentimentoCandidato() {
  const c = app.talentoAberto;
  if (!c) return;
  const { error } = await db.rpc('registrar_consentimento', { p_candidato_id: c.id, p_origem: 'confirmado_pelo_candidato' });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  fecharModal('modal-editar-candidato');
  toast('Consentimento registrado');
  await recarregarTalento();
}

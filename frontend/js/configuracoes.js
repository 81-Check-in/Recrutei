// ═══════════════════════════════════════════════════════════
//  CONFIGURAÇÕES (somente administrador)
// ═══════════════════════════════════════════════════════════

// ── Catálogo da tela: nome claro, explicação em linguagem simples e o que cada campo realmente faz ──
// titulo/ajuda: o que o RH lê. tipo: como o campo é preenchido. semEfeito: motivo, quando o campo hoje NÃO muda nada no sistema (fica
// visível, com o aviso). Para o aviso sumir depois que o campo voltar a valer, basta apagar a linha "semEfeito" dele.
const GRUPOS_CONFIG = [
  { id: 'email', atalho: 'Leitura de e-mails', titulo: 'Leitura dos e-mails',
    descricao: 'Quando o robô lê a caixa de e-mail e busca os currículos que chegaram (horário de Brasília).',
    chaves: ['leitura_dias_semana', 'leitura_hora_inicio', 'leitura_hora_fim', 'leitura_intervalo_minutos', 'tamanho_minimo_anexo_bytes'] },
  { id: 'ia', atalho: 'Inteligência artificial', titulo: 'Inteligência artificial (IA)',
    descricao: 'Quais IAs analisam os currículos, quanto elas precisam ter certeza e quanto isso custa.',
    chaves: ['modelo_ia_classificacao', 'modelo_ia_avaliacao', 'ia_confianca_minima'] },
  { id: 'limpeza', atalho: 'Limpeza do banco (LGPD)', titulo: 'Limpeza do Banco de Talentos (sanitização e LGPD)',
    descricao: 'O sistema monta uma lista de candidatos que talvez devam sair do banco e o RH decide: manter ou inativar. Quem fica inativo tem os dados pessoais apagados sozinho depois do prazo abaixo.',
    chaves: ['expurgo_meses_apos_inativar', 'sanitizacao_intervalo_dias', 'sanitizacao_meses_sem_movimentacao', 'sanitizacao_retencao_maxima_meses',
             'sanitizacao_reprovacoes_max', 'sanitizacao_confianca_min', 'sanitizacao_detectar_duplicidade',
             'sanitizacao_adiar_meses', 'sanitizacao_emails_aviso', 'sanitizacao_pesos'] },
  { id: 'whatsapp', atalho: 'WhatsApp e telefones', titulo: 'WhatsApp e telefones',
    descricao: 'Mensagem de convocação para entrevista e como os telefones são completados.',
    chaves: ['mensagem_convocacao_padrao', 'ddi_padrao', 'ddd_padrao'] }
];

const CONFIG_INFO = {
  leitura_dias_semana: { tipo: 'dias', titulo: 'Dias da semana em que o robô lê os e-mails',
    ajuda: 'O robô só lê a caixa e analisa currículos nos dias marcados, dentro do horário abaixo. Padrão: segunda a sábado. Fora deles ele continua ligado (a tela Status mostra isso), mas não lê e-mails nem chama a IA.' },
  leitura_hora_inicio: { tipo: 'hora', titulo: 'Começa a ler os e-mails às',
    ajuda: 'Primeira hora do dia em que o robô lê a caixa (horário de Brasília). Padrão: 07:30. O e-mail que chegou de noite ou no domingo é lido nessa hora.' },
  leitura_hora_fim: { tipo: 'hora', titulo: 'Para de ler os e-mails às',
    ajuda: 'A partir desta hora o robô não lê mais naquele dia: às 18:00, por exemplo, a leitura das 18:00 já não acontece. Padrão: 18:00. Tem de ser depois do horário de início.' },
  leitura_intervalo_minutos: { tipo: 'numero', min: 1, max: 240, obrigatorio: true, inteiro: true, unidade: 'minutos', titulo: 'De quantos em quantos minutos ler os e-mails',
    ajuda: 'A cada quanto tempo o robô busca os e-mails não lidos, dentro do horário. Padrão: 10. Currículo enviado pelo painel e pedido de "tentar de novo" não esperam esse intervalo: saem em cerca de 1 minuto.' },
  tamanho_minimo_anexo_bytes: { tipo: 'numero', min: 1024, max: 1048576, unidade: 'bytes (10240 = 10 KB)', titulo: 'Tamanho mínimo de imagem anexada',
    ajuda: 'Imagens anexadas menores que isso (logotipos e ícones de assinatura de e-mail) são ignoradas. Documentos (PDF, DOC, DOCX) só são ignorados abaixo de 500 bytes, um piso fixo de propósito: um PDF só de texto tem poucos KB e pode ser um currículo de verdade.' },

  modelo_ia_classificacao: { tipo: 'modelo', titulo: 'IA que identifica o currículo (a mais barata)',
    ajuda: 'Lê o e-mail e decide se é um currículo; tira nome, cidade, escolaridade, experiência e CNH; e estima o sexo pelo primeiro nome. Um modelo simples já basta. Recomendado: manter o padrão.' },
  modelo_ia_avaliacao: { tipo: 'modelo', titulo: 'IA que analisa o currículo (a mais precisa)',
    ajuda: 'Classifica o currículo em setor, função e nível, escreve o resumo e dá a nota. Também escreve o rascunho de vaga. É a que mais pesa no custo.' },
  ia_confianca_minima: { tipo: 'numero', min: 0, max: 100, unidade: 'de 0 a 100', titulo: 'Confiança mínima da IA',
    ajuda: 'Se a IA ficar menos segura que isso ao classificar um currículo, ele aparece como "Revisão manual necessária". Valor mais alto = mais currículos para o RH conferir.' },
  expurgo_meses_apos_inativar: { tipo: 'numero', min: 1, max: 60, unidade: 'meses', titulo: 'Apagar os dados de quem está inativo há mais de',
    ajuda: 'Contado da data em que o candidato foi inativado (pelo botão Inativar ou pela sanitização). Passado o prazo, a rotina diária apaga nome, contatos, currículo e análises e guarda só o necessário para reconhecer um reenvio. NÃO dá para desfazer. Reativar o candidato antes disso reinicia a contagem. Contratado nunca é apagado.' },
  sanitizacao_intervalo_dias: { tipo: 'numero', min: 1, max: 60, unidade: 'dias', titulo: 'De quanto em quanto tempo conferir quem vai para a limpeza',
    ajuda: 'Com que frequência o sistema confere quem já completou o prazo e o coloca na lista de sugestões. 7 = toda semana: cada candidato entra na primeira conferência depois de completar o prazo (até 6 dias depois). 1 = todo dia.' },
  sanitizacao_meses_sem_movimentacao: { tipo: 'numero', min: 1, max: 120, unidade: 'meses', titulo: 'Sugerir quem está parado há mais de',
    ajuda: 'Prazo contado da data em que o candidato entrou no sistema (não da data do e-mail). Só entra na lista quem ficou esse tempo sem candidatura, novo currículo, contato nem edição; qualquer alteração reinicia a contagem. Vale para todos os motivos abaixo, que só somam pontos e prioridade. Única exceção: o prazo máximo no banco.' },
  sanitizacao_retencao_maxima_meses: { tipo: 'numero', min: 1, max: 240, unidade: 'meses', titulo: 'Prazo máximo no banco (LGPD)',
    ajuda: 'Depois deste prazo, contado da entrada (ou do consentimento, se estiver registrado), o candidato entra na lista com prioridade alta.' },
  sanitizacao_reprovacoes_max: { tipo: 'numero', min: 1, max: 50, unidade: 'vagas', titulo: 'Sugerir quem foi reprovado em',
    ajuda: 'Entra na lista quem foi reprovado em pelo menos essa quantidade de vagas diferentes e nunca foi aprovado.' },
  sanitizacao_confianca_min: { tipo: 'numero', min: 0, max: 100, unidade: 'de 0 a 100', titulo: 'Sugerir análises com pouca confiança',
    ajuda: 'Entra na lista (como "dados incompletos") quem a IA classificou com confiança abaixo deste valor, ou sem setor, função e nível.' },
  sanitizacao_detectar_duplicidade: { tipo: 'booleano', titulo: 'Sugerir cadastros repetidos',
    ajuda: 'Quando a mesma pessoa aparece duas vezes (mesma identidade, ou mesmo telefone ou e-mail com nome parecido), sugere o cadastro mais antigo.' },
  sanitizacao_adiar_meses: { tipo: 'numero', min: 1, max: 60, unidade: 'meses', titulo: 'Ao manter um candidato, não sugerir de novo por',
    ajuda: 'Quando o RH decide manter alguém na lista de limpeza, ele fica fora das próximas listas por esse tempo.' },
  sanitizacao_emails_aviso: { tipo: 'texto', titulo: 'Quem recebe o aviso por e-mail',
    ajuda: 'E-mails separados por vírgula (ex.: rh@empresa.com, gestor@empresa.com). Vazio = o aviso aparece só dentro do sistema. O e-mail traz apenas contagens, nunca dados de candidato.' },
  sanitizacao_pesos: { tipo: 'json', titulo: 'Pontos de cada motivo (avançado)',
    ajuda: 'Cada motivo vale pontos; a soma define a prioridade da sugestão: alta se chegar a limite_alta, média se chegar a limite_media, senão baixa. Mexa só se souber o que está fazendo (o peso baixa_aderencia não tem efeito, pelo mesmo motivo da regra de nota baixa).' },

  mensagem_convocacao_padrao: { tipo: 'mensagem', titulo: 'Mensagem de convocação do WhatsApp',
    ajuda: 'Texto sugerido ao agendar a entrevista (o RH ainda pode editar antes de enviar). Use os marcadores {nome}, {gestor}, {data} e {hora}: eles são trocados pelos dados da entrevista.' },
  ddi_padrao: { tipo: 'digitos', digitos: [1, 3], titulo: 'Código do país dos telefones (DDI)',
    ajuda: 'Acrescentado aos telefones que vêm sem ele (55 = Brasil), ao ler currículos e ao abrir o WhatsApp. De 1 a 3 números.' },
  ddd_padrao: { tipo: 'digitos', digitos: [2, 2], titulo: 'DDD assumido quando o telefone vem sem DDD',
    ajuda: 'Usado só quando o número vem sem DDD (61 = Distrito Federal). Cadastros que já estão no banco não mudam. 2 números.' }
};

const _semAcento = t => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

function htmlControleConfig(c, info) {
  const id = `cfg-${c.chave}`;
  const valor = typeof c.valor === 'string' ? c.valor : JSON.stringify(c.valor);
  if (info.tipo === 'modelo')
    return `<select class="config-input" id="${id}" onchange="atualizarEstimativas()">${opcoesModelo(valor, c.chave)}</select>`;
  if (info.tipo === 'digitos')
    return `<input class="config-input" id="${id}" value='${escapeHtml(valor)}' inputmode="numeric" maxlength="${info.digitos[1]}" autocomplete="off">`;
  if (info.tipo === 'hora')
    return `<input class="config-input" id="${id}" type="time" value="${escapeHtml(valor)}" required>`;
  if (info.tipo === 'dias') {                                   // 1 = segunda ... 7 = domingo, como o robô lê (backend/agenda.py)
    const marcados = new Set(Array.isArray(c.valor) ? c.valor.map(Number) : []);
    return `<div class="config-dias" id="${id}" role="group" aria-label="Dias da semana">` +
      [[1, 'Seg'], [2, 'Ter'], [3, 'Qua'], [4, 'Qui'], [5, 'Sex'], [6, 'Sáb'], [7, 'Dom']].map(([n, r]) =>
        `<label class="config-dia"><input type="checkbox" value="${n}"${marcados.has(n) ? ' checked' : ''}><span>${r}</span></label>`).join('') +
      '</div>';
  }
  if (info.tipo === 'booleano')
    return `<select class="config-input" id="${id}"><option value="true"${valor === 'true' ? ' selected' : ''}>Sim</option>` +
           `<option value="false"${valor === 'false' ? ' selected' : ''}>Não</option></select>`;
  if (info.tipo === 'mensagem' || info.tipo === 'json')
    return `<textarea class="config-input larga${info.tipo === 'json' ? ' mono' : ''}" id="${id}" rows="${info.tipo === 'json' ? 5 : 3}">${escapeHtml(info.tipo === 'json' ? JSON.stringify(c.valor, null, 1) : valor)}</textarea>`;
  if (info.tipo === 'numero')
    return `<input class="config-input" id="${id}" type="number" step="1"` +
           `${info.min != null ? ` min="${info.min}"` : ''}${info.max != null ? ` max="${info.max}"` : ''} value="${escapeHtml(valor)}">`;
  return `<input class="config-input" id="${id}" value='${escapeHtml(valor)}'>`;
}

function htmlItemConfig(c) {
  const info = CONFIG_INFO[c.chave] || { tipo: 'texto', titulo: c.chave, ajuda: c.descricao || '' };
  const ehModelo = info.tipo === 'modelo';
  return `
    <div class="config-item">
      <div class="config-info">
        <div class="config-titulo">${escapeHtml(info.titulo)}${info.semEfeito ? ' <span class="config-tag-sem-efeito">Sem efeito hoje</span>' : ''}</div>
        <div class="config-desc">${escapeHtml(info.ajuda || c.descricao || '')}</div>
        ${info.semEfeito ? `<div class="config-aviso"><i class="ti ti-info-circle" aria-hidden="true"></i> ${escapeHtml(info.semEfeito)}</div>` : ''}
        <div class="config-chave tec">${c.chave}</div>
        ${ehModelo ? `<div class="config-est" id="est-${c.chave}"></div>` : ''}
      </div>
      <div class="config-controle">
        ${htmlControleConfig(c, info)}
        ${info.unidade ? `<span class="config-unidade">${escapeHtml(info.unidade)}</span>` : ''}
      </div>
      <button class="btn-sm azul" onclick="salvarConfig('${c.chave}')">Salvar</button>
    </div>`;
}

async function carregarConfig() {
  const el = $('#config-lista');
  loading(el);

  const { data, error } = await db.from('configuracoes').select('*').order('chave');
  if (error) { erro(el, error.message); return; }

  const grupos = GRUPOS_CONFIG.map(g => {
    const itens = g.chaves.map(k => data.find(c => c.chave === k)).filter(Boolean);     // na ordem do catálogo, não em ordem alfabética
    if (!itens.length) return '';
    return `<div class="config-grupo" id="cfg-grupo-${g.id}" data-atalho="${escapeHtml(g.atalho)}">
      <h3>${escapeHtml(g.titulo)}</h3>
      <div class="config-grupo-desc">${escapeHtml(g.descricao)}</div>
      ${itens.map(htmlItemConfig).join('')}
      ${CHAVES_MODELO.every(k => itens.some(c => c.chave === k)) ? '<div class="config-total" id="est-total"></div>' : ''}
    </div>`;
  }).join('');

  el.innerHTML = `
    <div class="config-ferramentas">
      <div class="busca"><i class="ti ti-search" aria-hidden="true"></i>
        <input id="config-busca" type="search" autocomplete="off" oninput="filtrarConfig()"
               placeholder="Buscar configuração (ex.: e-mail, IA, meses, WhatsApp, nível)" aria-label="Buscar configuração"></div>
      <div class="config-atalhos" id="config-atalhos" aria-label="Ir direto para"></div>
    </div>
    ${grupos}
    <div class="estado-vazio" id="config-sem-resultado" style="display:none"><i class="ti ti-search-off"></i>Nenhuma configuração encontrada para essa busca.</div>`;
  atualizarEstimativas();
  await carregarNiveisConfig(el);
  await carregarZonaDePerigo(el);
  montarAtalhosConfig();
}

// ── Busca e atalhos: achar um campo sem rolar a tela toda ──
function montarAtalhosConfig() {
  const alvo = $('#config-atalhos');
  if (!alvo) return;
  alvo.innerHTML = [...$$('#config-lista .config-grupo[data-atalho]')].map(g =>
    `<button type="button" class="config-atalho" onclick="irParaGrupoConfig('${g.id}')">${escapeHtml(g.dataset.atalho)}</button>`).join('');
}

function irParaGrupoConfig(id) {
  const busca = $('#config-busca');
  if (busca && busca.value) { busca.value = ''; filtrarConfig(); }         // com um filtro ativo o grupo poderia estar escondido
  $('#' + id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function filtrarConfig() {
  const termo = _semAcento($('#config-busca')?.value.trim());
  let visiveis = 0;
  $$('#config-lista .config-grupo').forEach(grupo => {
    let algum = false;
    grupo.querySelectorAll('.config-item').forEach(item => {
      const bate = !termo || _semAcento(item.textContent).includes(termo) || _semAcento(grupo.querySelector('h3')?.textContent).includes(termo);
      item.style.display = bate ? '' : 'none';
      algum = algum || bate;
    });
    grupo.style.display = algum ? '' : 'none';
    visiveis += algum ? 1 : 0;
  });
  const vazio = $('#config-sem-resultado');
  if (vazio) vazio.style.display = visiveis ? 'none' : '';
}

// ── Zona de perigo: pausa de emergência da IA ──
// ia_pausada (backend/sql/040) = true: o robô (Railway) e o servidor HTTP deixam de enviar QUALQUER coisa à IA. Nada se perde: e-mails,
// envios manuais e pedidos de análise ficam como estão e seguem quando o administrador retoma. O mesmo botão desfaz.
async function carregarZonaDePerigo(el) {
  const { data, error } = await db.from('configuracoes').select('valor,updated_at,updated_by').eq('chave', CHAVE_IA_PAUSADA).maybeSingle();
  if (error || !data) return;                       // migração 040 ainda não rodada: sem a linha não há o que pausar
  let quem = null;
  if (data.valor === true && data.updated_by) {
    const { data: u } = await db.from('usuarios').select('nome').eq('id', data.updated_by).maybeSingle();
    quem = u?.nome || null;
  }
  el.querySelector('#config-perigo')?.remove();
  el.insertAdjacentHTML('beforeend', htmlZonaDePerigo(data.valor === true, data.updated_at, quem));
}

function htmlZonaDePerigo(pausada, quando, quem) {
  const estado = pausada
    ? `<div class="perigo-estado parada"><i class="ti ti-player-pause"></i> PAUSADO${quando ? ' desde ' + fmtDataHora(quando) : ''}${quem ? ' por ' + escapeHtml(quem) : ''}</div>`
    : '<div class="perigo-estado ok">Funcionando normalmente</div>';
  return `<div class="config-grupo zona-perigo${pausada ? ' pausada' : ''}" id="config-perigo" data-atalho="Zona de perigo">
    <h3><i class="ti ti-alert-triangle"></i> Zona de perigo</h3>
    <div class="config-item">
      <div class="config-info">
        <div class="config-chave">ia_pausada</div>
        <div class="config-desc">Último recurso. Pausado, o robô não lê e-mails nem analisa currículos, e "Reanalisar", "Enviar currículo" e o rascunho de vaga por IA
          avisam que a IA está pausada. <strong>Nada se perde</strong>: e-mails e pedidos ficam como estão e seguem quando você retomar.
          Vale em poucos segundos; uma execução em andamento para no próximo envio. Se a pausa cobrir o horário da leitura diária,
          ela só volta no dia seguinte (ou quando o robô for rodado à mão).</div>
        ${estado}
      </div>
      <button class="btn-sm ${pausada ? 'azul' : 'vermelho'} config-btn-perigo" onclick="alternarPausaIA(${pausada ? 'false' : 'true'})">
        ${pausada ? 'Retomar envio à IA' : 'Pausar todo envio à IA'}</button>
    </div>
  </div>`;
}

// Pausar é a ação perigosa: abre o modal que explica o que acontece e o que se perde e só segue com a senha (confirmarPausaIA).
// Retomar só volta a gastar, então basta a confirmação simples.
async function alternarPausaIA(pausar) {
  if (pausar) { abrirPausaIA(); return; }
  const ok = await confirmar({ titulo: 'Retomar o envio à IA?', rotulo: 'Retomar', perigo: false,
    mensagem: 'O robô e o painel voltam a enviar currículos e pedidos à IA, o que gera custo. A leitura diária dos e-mails volta no próximo horário configurado.' });
  if (!ok) return;
  await gravarPausaIA(false);
}

function abrirPausaIA() {
  const senha = $('#pausa-ia-senha');
  senha.value = '';
  $('#pausa-ia-erro').style.display = 'none';
  atualizarBotaoPausaIA();
  abrirModal('modal-pausar-ia');
  // o foco começa em "Cancelar": quem só der Enter não pausa nada (o botão de pausar também só liga com a senha digitada)
  setTimeout(() => $('#pausa-ia-cancelar')?.focus(), 0);
}

function fecharPausaIA() {
  $('#pausa-ia-senha').value = '';                  // a senha não fica na tela
  fecharModal('modal-pausar-ia');
}

function atualizarBotaoPausaIA() {
  $('#pausa-ia-ok').disabled = !$('#pausa-ia-senha').value;
}

// Confere a senha de quem está logado SEM mexer na sessão do painel: usa um cliente descartável (nada é guardado no navegador).
// É uma trava contra clique por engano ou tela deixada aberta; a permissão de verdade continua sendo do banco (só administrador altera).
async function verificarSenhaAtual(senha) {
  const email = app.usuario?.email;
  if (!email) return { ok: false, msg: 'Não consegui identificar o seu usuário. Entre de novo no painel.' };
  const descartavel = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: 'recrutei-conferir-senha' }
  });
  const { error } = await descartavel.auth.signInWithPassword({ email, password: senha });
  if (!error) return { ok: true };
  return { ok: false, msg: error.message === 'Invalid login credentials' ? 'Senha incorreta.' : mensagemErro(error) };
}

async function confirmarPausaIA(ev) {
  ev?.preventDefault();
  const senha = $('#pausa-ia-senha').value;
  if (!senha) return;
  const btn = $('#pausa-ia-ok');
  const erro = $('#pausa-ia-erro');
  btn.disabled = true;
  btn.innerHTML = '<i class="ti ti-loader-2 girando"></i> Conferindo...';
  const r = await verificarSenhaAtual(senha);
  btn.innerHTML = 'Pausar todo envio à IA';
  if (!r.ok) {
    erro.textContent = r.msg;
    erro.style.display = 'block';
    $('#pausa-ia-senha').select();
    atualizarBotaoPausaIA();
    return;
  }
  fecharPausaIA();
  await gravarPausaIA(true);
}

async function gravarPausaIA(pausar) {
  // .select() confirma que a linha mudou de fato: sem permissão (não administrador) o banco não dá erro, só não altera nada
  const { data, error } = await db.from('configuracoes')
    .update({ valor: pausar, updated_by: app.usuario.id }).eq('chave', CHAVE_IA_PAUSADA).select('valor,updated_at');
  if (error || !data?.length) {
    toast(error ? mensagemErro(error) : 'Não foi possível alterar: só o administrador pode mexer aqui', 'erro');
    carregarZonaDePerigo($('#config-lista'));      // mostra o estado que o banco realmente tem
    return;
  }
  toast(pausar ? 'Envio à IA PAUSADO' : 'Envio à IA retomado', pausar ? 'erro' : 'ok');
  await carregarZonaDePerigo($('#config-lista'));
}

// ── Níveis da qualificação dos currículos ──
// O administrador habilita/desabilita Jovem Aprendiz e Trainee (para auditar a classificação) e reescreve o critério de qualquer
// nível. Desabilitado: a IA deixa de receber o nível e o formulário da vaga deixa de oferecê-lo; o que já o tem continua como está.
// Cada mudança fica na auditoria (alterar_nivel_funcao, backend/sql/036). Júnior, Pleno e Sênior não desabilitam.
async function carregarNiveisConfig(el) {
  const { data, error } = await db.from('niveis_funcao').select('codigo,nome,descricao,ativo,ordem').order('ordem');
  if (error || !data?.length) return;
  el.insertAdjacentHTML('beforeend', `<div class="config-grupo" id="config-niveis" data-atalho="Níveis de experiência">
    <h3>Níveis de experiência (qualificação dos currículos)</h3>
    <div class="config-desc" style="margin:-6px 0 8px">O critério é o que a IA lê para escolher o nível. <strong>Jovem Aprendiz</strong> e <strong>Trainee</strong>
      só existem nos cargos que os aceitam (Logística/Auxiliar, DP/Auxiliar, RH/Auxiliar, Loja/Repositor) e podem ser habilitados ou desabilitados aqui.
      Desabilitado, a IA deixa de usar o nível e o formulário da vaga deixa de oferecê-lo; currículos e vagas que já o têm continuam como estão.
      Cada mudança fica registrada na auditoria.</div>
    ${data.map(n => {
      const alternavel = NIVEIS_INICIANTES.includes(n.codigo);
      return `<div class="config-item" style="align-items:flex-start">
        <div class="config-info" style="flex:1">
          <div class="config-chave">${escapeHtml(n.nome)} <span style="font-weight:400;color:var(--gray-text)">(${n.codigo})</span></div>
          <textarea class="config-input" id="nivel-desc-${n.codigo}" rows="2" style="width:100%;margin-top:6px">${escapeHtml(n.descricao || '')}</textarea>
        </div>
        <label class="config-toggle" title="${alternavel ? 'Habilita ou desabilita o nível' : 'Júnior, Pleno e Sênior são a base da classificação: não podem ser desabilitados'}">
          <input type="checkbox" id="nivel-ativo-${n.codigo}" ${n.ativo ? 'checked' : ''} ${alternavel ? '' : 'disabled'}> Habilitado
        </label>
        <button class="btn-sm azul" onclick="salvarNivel('${n.codigo}')">Salvar</button>
      </div>`;
    }).join('')}
  </div>`);
}

async function salvarNivel(codigo) {
  const alternavel = NIVEIS_INICIANTES.includes(codigo);
  const { error } = await db.rpc('alterar_nivel_funcao', {
    p_codigo: codigo,
    p_ativo: alternavel ? $(`#nivel-ativo-${codigo}`).checked : null,     // os três níveis-base nunca mudam de estado
    p_descricao: $(`#nivel-desc-${codigo}`).value
  });
  if (error) { toast(mensagemErro(error), 'erro'); return; }
  // o formulário da vaga desta sessão já reflete a mudança; quem estiver com o painel aberto vê ao recarregar (o banco recusa de qualquer forma)
  const { data } = await db.from('niveis_funcao').select('codigo,nome').eq('ativo', true).order('ordem');
  if (data) app.cache.niveis = data;
  toast('Nível salvo');
}

// Preços por 1M tokens (US$). Manter igual a PRECOS em backend/config.py.
// tokenizador: os modelos 4.7+ contam ~30% mais tokens para o mesmo texto que o Haiku 4.5.
// raciocinio: tokens extras de saída estimados (esforço baixo); Sonnet 5 roda sem raciocínio.
const MODELOS_IA = [
  { id: 'claude-fable-5-1',          nome: 'Fable 5.1', entrada: 10, saida: 50, tokenizador: 1.3, raciocinio: 300 },
  { id: 'claude-opus-5',             nome: 'Opus 5',    entrada: 5,  saida: 25, tokenizador: 1.3, raciocinio: 300 },
  { id: 'claude-sonnet-5',           nome: 'Sonnet 5',  entrada: 2,  saida: 10, tokenizador: 1.3, raciocinio: 0 },
  { id: 'claude-haiku-4-5-20251001', nome: 'Haiku 4.5', entrada: 1,  saida: 5,  tokenizador: 1,   raciocinio: 0 }
];
const CHAVES_MODELO = ['modelo_ia_classificacao', 'modelo_ia_avaliacao'];
// Tamanho típico de uma chamada, em tokens do tokenizador do Haiku (estimativa, não medida)
const USO_TIPICO = {
  modelo_ia_classificacao: { entrada: 2800, saida: 120 },
  modelo_ia_avaliacao:     { entrada: 2400, saida: 400 }
};
const SALDO_REFERENCIA_USD = 5;

const usd = v => 'US$ ' + (v >= 1 ? v.toFixed(2) : v.toFixed(4)).replace('.', ',');

// Modelos padrão (espelham config.py): Haiku classifica, Sonnet avalia
const MODELO_PADRAO = {
  modelo_ia_classificacao: 'claude-haiku-4-5-20251001',
  modelo_ia_avaliacao:     'claude-sonnet-5'
};

function opcoesModelo(valor, chave) {
  const padrao = MODELO_PADRAO[chave];
  const vazio = !valor || valor === 'null' || !valor.trim();   // vazio = o backend usa o padrão
  const atual = vazio ? padrao : valor;
  const opcoes = MODELOS_IA.map(m =>
    `<option value="${m.id}"${m.id === atual ? ' selected' : ''}>${m.nome}${m.id === padrao ? ' (padrão)' : ''}</option>`);
  if (!MODELOS_IA.some(m => m.id === atual)) {   // valor fora da lista: não some em silêncio
    opcoes.push(`<option value="${escapeHtml(atual)}" selected>${escapeHtml(atual)} (personalizado)</option>`);
  }
  return opcoes.join('');
}

function custoPorCurriculo(chave, modeloId) {
  const m = MODELOS_IA.find(x => x.id === modeloId);
  if (!m) return null;
  const u = USO_TIPICO[chave];
  const porChamada = (u.entrada * m.tokenizador * m.entrada +
                      (u.saida * m.tokenizador + m.raciocinio) * m.saida) / 1e6;
  return porChamada;
}

function atualizarEstimativas() {
  let total = 0, completo = true;
  CHAVES_MODELO.forEach(k => {
    const sel = $(`#cfg-${k}`), el = $(`#est-${k}`);
    if (!sel || !el) { completo = false; return; }
    const m = MODELOS_IA.find(x => x.id === sel.value);
    const c = custoPorCurriculo(k, sel.value);
    if (c === null) {
      el.textContent = 'Modelo fora da lista: custo não estimado (o log mostrará US$ 0,00).';
      completo = false;
      return;
    }
    total += c;
    el.textContent = `${m.nome}: ${usd(m.entrada)} entrada / ${usd(m.saida)} saída por 1M tokens · ` +
      `≈ ${usd(c)} por currículo · ${usd(c * 100)} a cada 100`;
  });
  const tot = $('#est-total');
  if (tot) {
    tot.textContent = completo && total
      ? `Estimativa com essas escolhas: ≈ ${usd(total)} por currículo · ${usd(total * 100)} a cada 100 · ` +
        `US$ ${SALDO_REFERENCIA_USD} rendem ≈ ${Math.floor(SALDO_REFERENCIA_USD / total)} currículos. ` +
        'Aproximado; o custo real aparece no log de cada execução.'
      : '';
  }
}

const CHAVE_IA_PAUSADA = 'ia_pausada';
const HORA_VALIDA = /^([01]\d|2[0-3]):[0-5]\d$/;                     // o robô lê "HH:MM"; qualquer outra coisa cairia no padrão em silêncio

async function gravarConfig(chave, valor) {
  const { error } = await db.from('configuracoes')
    .update({ valor, updated_by: app.usuario.id }).eq('chave', chave);
  return error;
}

// Dias da semana do robô: os marcados viram uma lista de números (1 = segunda ... 7 = domingo)
async function salvarDiasConfig(chave) {
  const dias = [...$$(`#cfg-${chave} input:checked`)].map(i => Number(i.value)).sort((a, b) => a - b);
  if (!dias.length) { toast('Marque pelo menos um dia da semana', 'erro'); return; }
  const error = await gravarConfig(chave, dias);
  toast(error ? error.message : 'Configuração salva', error ? 'erro' : 'ok');
}

async function salvarConfig(chave) {
  const info = CONFIG_INFO[chave] || {};
  if (info.tipo === 'dias') return salvarDiasConfig(chave);
  const raw = $(`#cfg-${chave}`).value;
  if (info.tipo === 'hora' && !HORA_VALIDA.test(raw)) {
    toast('Informe o horário no formato HH:MM (ex.: 07:30)', 'erro');
    return;
  }
  if (chave === 'leitura_hora_inicio' || chave === 'leitura_hora_fim') {          // a janela precisa ter começo antes do fim
    const inicio = chave === 'leitura_hora_inicio' ? raw : $('#cfg-leitura_hora_inicio')?.value;
    const fim = chave === 'leitura_hora_fim' ? raw : $('#cfg-leitura_hora_fim')?.value;
    if (HORA_VALIDA.test(inicio || '') && HORA_VALIDA.test(fim || '') && inicio >= fim) {
      toast('O horário de início precisa ser antes do horário de fim', 'erro');
      return;
    }
  }
  const semValor = raw.trim() === '';
  if (info.tipo === 'numero' && ((semValor && info.obrigatorio) || (!semValor && (isNaN(Number(raw)) || (info.inteiro && !Number.isInteger(Number(raw))) || (info.min != null && Number(raw) < info.min) || (info.max != null && Number(raw) > info.max))))) {
    toast(`Informe um número${info.min != null && info.max != null ? ` de ${info.min} a ${info.max}` : ''}`, 'erro');
    return;
  }
  if (info.tipo === 'digitos' && !new RegExp(`^\\d{${info.digitos[0]},${info.digitos[1]}}$`).test(raw.trim())) {
    toast(`Informe só números, de ${info.digitos[0]} a ${info.digitos[1]} dígito${info.digitos[1] > 1 ? 's' : ''} (ex.: ${chave === 'ddd_padrao' ? '61' : '55'})`, 'erro');
    return;
  }
  if (info.tipo === 'mensagem') {
    const desconhecido = [...raw.matchAll(/\{([^}]*)\}/g)].map(m => m[1]).find(k => !['nome', 'gestor', 'data', 'hora'].includes(k));
    if (!raw.trim() || desconhecido !== undefined) {
      toast(!raw.trim() ? 'A mensagem não pode ficar vazia' : `Marcador {${desconhecido}} desconhecido. Use {nome}, {gestor}, {data} e {hora}`, 'erro');
      return;
    }
  }
  if (info.tipo === 'json') {                   // um JSON com vírgula fora do lugar quebraria a regra que o lê: não deixa salvar
    let objeto = null;
    try { objeto = JSON.parse(raw); } catch { /* cai na mensagem abaixo */ }
    if (!objeto || typeof objeto !== 'object' || Array.isArray(objeto)) {
      toast('Formato inválido. Confira as chaves, os dois-pontos e as vírgulas (ex.: {"limite_alta": 4})', 'erro');
      return;
    }
  }
  let valor;
  try { valor = JSON.parse(raw); }
  catch { valor = raw; }
  if (info.tipo === 'digitos') valor = raw.trim();          // fica texto ("55"), não número: é como o robô e o painel leem
  if (info.tipo === 'mensagem') valor = raw;                // texto livre: nunca interpretado como JSON (uma mensagem só com números viraria número)

  const error = await gravarConfig(chave, valor);
  toast(error ? error.message : 'Configuração salva', error ? 'erro' : 'ok');
  if (!error && CHAVES_CONFIG_DO_PAINEL.includes(chave)) app.cache.config[chave] = valor;   // vale já nesta sessão, sem recarregar
  atualizarEstimativas();
}


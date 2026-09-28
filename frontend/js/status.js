// ═══════════════════════════════════════════════════════════
//  STATUS DO ROBÔ
//  O robô (backend/robo.py) grava o andamento em pipeline_status (uma linha, migração 046) a cada ciclo; o painel só lê.
//  "Aguardando leitura" é a contagem de não lidos da última checagem do robô, por isso a tela sempre diz de que hora ela é.
//  Sem sinal do robô há alguns minutos = ele parou (o Railway caiu, o deploy falhou): é o aviso mais importante da tela.
// ═══════════════════════════════════════════════════════════

const SINAL_VELHO_MIN = 6;                // o robô dá sinal a cada ~1 min (a cada 5 no modo cron): sem sinal por mais que isto, parou
const MONITOR_CADA_S = 15;
let monitorDoRobo = null;
let statusAtual = null;                   // {linha, excecoes, config} da última consulta

const DIAS_ISO = { 1: 'segunda', 2: 'terça', 3: 'quarta', 4: 'quinta', 5: 'sexta', 6: 'sábado', 7: 'domingo' };

// Há quanto tempo, em palavras ("há 3 min", "há 2 h")
function haQuantoTempo(iso, agora = Date.now()) {
  const min = Math.max(0, Math.floor((agora - new Date(iso)) / 60000));
  if (min < 1) return 'agora há pouco';
  if (min < 60) return `há ${min} min`;
  if (min < 1440) return `há ${Math.floor(min / 60)} h`;
  return `há ${Math.floor(min / 1440)} dia(s)`;
}

// Quando, para o cartão ("10:05") e para a frase ("às 10:05"). Outro dia que não hoje leva o dia da semana ("segunda, 07:30" / "segunda às 07:30").
function partesDoQuando(iso, agora = new Date()) {
  const d = new Date(iso);
  const hora = d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  const dia = d.toDateString() === agora.toDateString() ? null : d.toLocaleDateString('pt-BR', { weekday: 'long' }).replace('-feira', '');
  return { hora, dia };
}
function quandoCurto(iso, agora = new Date()) {
  if (!iso) return '—';
  const { hora, dia } = partesDoQuando(iso, agora);
  return dia ? `${dia}, ${hora}` : hora;
}
function quandoEmFrase(iso, agora = new Date()) {
  const { hora, dia } = partesDoQuando(iso, agora);
  return dia ? `${dia} às ${hora}` : `às ${hora}`;
}

// O que a tela mostra: o estado que o robô gravou, corrigido pela idade do último sinal
function interpretarStatus(linha, agora = Date.now()) {
  if (!linha)
    return { chave: 'sem-dados', titulo: 'Sem informação do robô',
             detalhe: 'O robô ainda não deu nenhum sinal. Confira se o serviço está ligado no Railway.' };
  const idade = (agora - new Date(linha.verificado_em)) / 60000;
  if (idade > SINAL_VELHO_MIN)
    return { chave: 'sem-sinal', titulo: 'Sem sinal do robô',
             detalhe: `Último sinal ${haQuantoTempo(linha.verificado_em, agora)}. Nada está sendo lido. Confira o serviço no Railway.` };
  const proxima = linha.proxima_leitura_em ? quandoEmFrase(linha.proxima_leitura_em, new Date(agora)) : null;
  switch (linha.estado) {
    case 'processando': {
      const andamento = linha.processando_total > 0 ? ` (${linha.processando_feitos} de ${linha.processando_total})` : '';
      return { chave: 'processando', titulo: 'Processando agora', detalhe: `${linha.atividade || 'Trabalhando'}${andamento}` };
    }
    case 'fora_do_horario':
      return { chave: 'fora', titulo: 'Fora do horário de leitura',
               detalhe: proxima ? `O robô está ligado e volta a ler os e-mails ${proxima}.` : 'O robô está ligado e volta no próximo horário de leitura.' };
    case 'pausado':
      return { chave: 'pausado', titulo: 'IA pausada',
               detalhe: 'O envio à IA está pausado (Configurações → Zona de perigo). Nada é lido nem analisado até retomar.' };
    case 'erro':
      return { chave: 'erro', titulo: 'Erro na última leitura', detalhe: linha.ultimo_erro || 'Veja o log do serviço no Railway.' };
    default:
      return { chave: 'ocioso', titulo: 'Robô ativo',
               detalhe: proxima ? `Esperando a próxima leitura, ${proxima}.` : 'Esperando a próxima leitura.' };
  }
}

const rotulosDias = dias => {
  const d = [...dias].sort((a, b) => a - b);
  if (d.join() === '1,2,3,4,5,6') return 'Segunda a sábado';
  if (d.join() === '1,2,3,4,5') return 'Segunda a sexta';
  if (d.join() === '1,2,3,4,5,6,7') return 'Todos os dias';
  return d.map(n => DIAS_ISO[n]).join(', ');
};

async function buscarStatus() {
  const [st, exc, cfg] = await Promise.all([
    db.from('pipeline_status').select('*').eq('id', true).limit(1),
    db.from('excecoes').select('id', { count: 'exact', head: true }).eq('status', 'pendente'),
    db.from('configuracoes').select('chave,valor')
      .in('chave', ['leitura_intervalo_minutos', 'leitura_hora_inicio', 'leitura_hora_fim', 'leitura_dias_semana'])
  ]);
  if (st.error) throw st.error;
  return { linha: st.data?.[0] || null, excecoes: exc.error ? null : exc.count,
           config: Object.fromEntries((cfg.data || []).map(c => [c.chave, c.valor])) };
}

// O ponto colorido do menu (todas as telas): mostra sem abrir a tela se o robô está bem
function pintarLuzDoMenu(interp) {
  const luz = $('#nav-status-luz');
  if (!luz) return;
  luz.className = `nav-luz ${interp.chave}`;
  luz.setAttribute('aria-label', `Estado do robô: ${interp.titulo}`);
  $('#nav-status').title = `Status do robô: ${interp.titulo}`;
}

function linhaStatus(rotulo, valor) {
  return `<div class="status-linha"><span>${escapeHtml(rotulo)}</span><b>${valor}</b></div>`;
}

function desenharUltimaLeitura(linha) {
  const el = $('#st-ultima');
  if (!linha?.ultima_leitura_em) {
    $('#st-ultima-sub').textContent = 'Nenhuma leitura registrada ainda';
    el.innerHTML = '<div class="estado-vazio"><i class="ti ti-mail-off"></i><span>Assim que o robô ler a caixa pela primeira vez, o resultado aparece aqui.</span></div>';
    return;
  }
  const r = linha.ultima_leitura_resumo || {};
  const terminou = !!linha.ultima_leitura_fim && new Date(linha.ultima_leitura_fim) >= new Date(linha.ultima_leitura_em);
  $('#st-ultima-sub').textContent = `${fmtDataHoraCompleta(linha.ultima_leitura_em)} · ${haQuantoTempo(linha.ultima_leitura_em)}`;
  const resultado = !terminou ? '<span class="pill pill-blue">Em andamento</span>'
    : linha.ultima_leitura_sucesso ? '<span class="pill pill-green"><i class="ti ti-check"></i>Concluída</span>'
    : '<span class="pill pill-red"><i class="ti ti-x"></i>Com erro</span>';
  const num = v => (v == null ? '—' : v);
  el.innerHTML = [
    linhaStatus('Resultado', resultado),
    terminou ? linhaStatus('Terminou às', fmtHora(linha.ultima_leitura_fim)) : '',
    linhaStatus('E-mails lidos', num(r.emails_lidos)),
    linhaStatus('Currículos novos no banco', num(r.curriculos_processados)),
    linhaStatus('Exceções geradas', num(r.excecoes_geradas)),
    linhaStatus('Reenvios reconhecidos', num(r.duplicados_detectados)),
    linhaStatus('Custo estimado da IA', r.custo_estimado_usd == null ? '—' : `US$ ${Number(r.custo_estimado_usd).toFixed(2)}`),
    linha.ultimo_erro && !linha.ultima_leitura_sucesso
      ? `<div class="status-erro"><i class="ti ti-alert-circle"></i>${escapeHtml(linha.ultimo_erro)}</div>` : ''
  ].join('');
}

function desenharRegras(cfg) {
  let dias = [1, 2, 3, 4, 5, 6];
  if (Array.isArray(cfg.leitura_dias_semana) && cfg.leitura_dias_semana.length) dias = cfg.leitura_dias_semana;
  const ini = typeof cfg.leitura_hora_inicio === 'string' ? cfg.leitura_hora_inicio : '07:30';
  const fim = typeof cfg.leitura_hora_fim === 'string' ? cfg.leitura_hora_fim : '18:00';
  const cada = Number(cfg.leitura_intervalo_minutos) || 10;
  const admin = app.perfil?.perfil === 'administrador';
  $('#st-regras').innerHTML = [
    linhaStatus('Dias', rotulosDias(dias)),
    linhaStatus('Horário', `${escapeHtml(ini)} às ${escapeHtml(fim)}`),
    linhaStatus('Lê os e-mails a cada', `${cada} min`),
    linhaStatus('Pedidos do RH (tentar de novo, currículo enviado, reanálise)', 'em cerca de 1 min'),
    '<div class="status-nota">Fora desse horário o robô fica ligado, mas não lê e-mails nem chama a IA: o que chegar espera a janela abrir. ' +
      'Os pedidos do RH também esperam.' +
      (admin ? ' <button type="button" class="link" onclick="irPara(\'config\')">Alterar em Configurações</button>' : '') + '</div>'
  ].join('');
}

function desenharStatus(dados, agora = Date.now()) {
  const { linha, excecoes, config } = dados;
  const interp = interpretarStatus(linha, agora);
  pintarLuzDoMenu(interp);
  if (app.telaAtual !== 'status') return;

  const topo = $('#status-topo');
  topo.className = `status-topo ${interp.chave}`;
  $('#status-estado').textContent = interp.titulo;
  $('#status-detalhe').textContent = interp.detalhe;
  $('#status-atualizado').textContent = linha ? `Último sinal do robô: ${haQuantoTempo(linha.verificado_em, agora)}` : '';

  const vivo = interp.chave !== 'sem-sinal' && interp.chave !== 'sem-dados';
  const processando = interp.chave === 'processando';
  const emails = processando && /e-mails/i.test(linha.atividade || '');

  // E-mails aguardando: a contagem do robô; enquanto ele lê, desce a cada e-mail tratado
  const aguardando = linha?.nao_lidos == null ? null : Math.max(0, linha.nao_lidos - (emails ? linha.processando_feitos : 0));
  $('#st-nao-lidos').textContent = aguardando == null ? '—' : aguardando;
  $('#st-nao-lidos-sub').textContent = linha?.nao_lidos_em ? `contados às ${fmtHora(linha.nao_lidos_em)}` : 'o robô ainda não contou';

  // Processando agora
  const total = linha?.processando_total || 0, feitos = linha?.processando_feitos || 0;
  $('#st-processando').textContent = processando && total ? `${feitos} de ${total}` : processando ? 'Trabalhando' : 'Nada';
  $('#st-barra-wrap').style.display = processando && total ? 'block' : 'none';
  $('#st-barra').style.width = total ? `${Math.min(100, Math.round(feitos / total * 100))}%` : '0%';
  $('#st-processando-sub').textContent = processando ? (linha.atividade || '') : (vivo ? 'O robô está esperando' : '');

  // Próxima leitura
  $('#st-proxima').textContent = vivo && linha?.proxima_leitura_em ? quandoCurto(linha.proxima_leitura_em, new Date(agora)) : '—';
  const falta = linha?.proxima_leitura_em ? Math.round((new Date(linha.proxima_leitura_em) - agora) / 60000) : null;
  $('#st-proxima-sub').textContent = !vivo ? 'sem sinal do robô'
    : interp.chave === 'pausado' ? 'IA pausada'
    : falta != null && falta > 0 && falta < 60 ? `em ${falta} min` : falta != null && falta <= 0 ? 'a qualquer momento' : '';

  $('#st-excecoes').textContent = excecoes == null ? '—' : excecoes;
  desenharUltimaLeitura(linha);
  desenharRegras(config || {});
}

async function carregarStatus() {
  if (!statusAtual) {                                   // primeira vez: mostra que está carregando em vez de números velhos
    $('#status-estado').textContent = 'Carregando…';
    $('#status-detalhe').textContent = '';
  }
  try {
    statusAtual = await buscarStatus();
    desenharStatus(statusAtual);
  } catch (e) {
    $('#status-topo').className = 'status-topo sem-dados';
    $('#status-estado').textContent = 'Não foi possível consultar o status';
    $('#status-detalhe').textContent = mensagemErro ? mensagemErro(e) : String(e.message || e);
  }
}

function irParaFilaDeExcecoes() {
  irPara('banco');
  const aba = $$('.tabs .tab')[1];
  if (aba) trocarAba('excecoes', aba);
}

// Consulta de tempos em tempos: pinta o ponto do menu e, com a tela aberta, redesenha os números. Aba escondida não consulta.
async function tickDoMonitor() {
  if (!app.usuario || document.hidden) return;
  try {
    statusAtual = await buscarStatus();
    desenharStatus(statusAtual);
  } catch { /* sem rede por um instante: fica o que estava */ }
}

function iniciarMonitorDoRobo() {
  pararMonitorDoRobo();
  tickDoMonitor();
  monitorDoRobo = setInterval(tickDoMonitor, MONITOR_CADA_S * 1000);
}

function pararMonitorDoRobo() {
  if (monitorDoRobo) clearInterval(monitorDoRobo);
  monitorDoRobo = null;
  statusAtual = null;
}

// ═══════════════════════════════════════════════════════════
//  DASHBOARD
// ═══════════════════════════════════════════════════════════

async function carregarDashboard() {
  const { data, error } = await db.from('vw_dashboard_metricas').select('*').single();
  if (error) { toast('Erro ao carregar métricas', 'erro'); return; }

  const p = app.periodo;
  $('#m-selecionados').textContent = (p === 7 ? data.selecionados_7d : data.selecionados_mes).toLocaleString('pt-BR');
  $('#m-entrevistas').textContent  = (p === 7 ? data.entrevistas_7d  : data.entrevistas_mes).toLocaleString('pt-BR');
  $('#m-excecoes').textContent = data.excecoes_pendentes;
  $('#m-revisao').textContent  = data.revisao_manual_pendente;
  $('#m-sanitizacao').textContent = data.sanitizacao_pendentes;
  atualizarBadgeSanitizacao(data.sanitizacao_pendentes);
  $('#m-curriculos').textContent = data.banco_ativos.toLocaleString('pt-BR');
  $('#periodo-label').textContent = p === 7 ? 'Últimos 7 dias' : 'Mês atual';

  await Promise.all([carregarFunil(data.banco_ativos), carregarEntrevistasContratacoes(), carregarSerieCvs(), carregarCvsPorRegiao(), carregarVagasResumo(), carregarExcecoesResumo()]);
}

// Do banco à contratação: todo o histórico, não o recorte do período (o funil não acompanha o seletor
// "7 dias / Mês atual"). A base é o total do Banco de Talentos; as demais etapas contam candidaturas
// atribuídas pelo RH (vínculos automáticos da triagem antiga não entram).
// bancoTotal = quem está disponível no banco (o mesmo número da tela Banco de Talentos, que abre em "Disponíveis")
async function carregarFunil(bancoTotal) {
  const { data, error } = await db
    .from('candidaturas')
    .select('status')
    .eq('status_registro', 'ativo')
    .neq('origem', 'triagem_legada');

  const el = $('#funil');
  if (error) { erro(el, mensagemErro(error)); return; }
  if (!bancoTotal) { vazio(el, 'ti-chart-bar', 'Nenhum candidato no banco'); return; }

  const conta = s => data.filter(d => s.includes(d.status)).length;
  const etapas = [
    { l: 'No banco',      v: bancoTotal, c: '#3B82F6' },
    { l: 'Atribuídos',    v: data.length, c: '#2563EB' },
    { l: 'Entrevistados', v: conta(['entrevista_realizada','aprovado','reprovado','contratado']), c: 'var(--funil-3)' },
    { l: 'Aprovados',     v: conta(['aprovado','contratado']), c: '#16A34A' },
    { l: 'Contratados',   v: conta(['contratado']), c: '#D97706' }
  ];

  el.innerHTML = etapas.map(e => {
    const pct = Math.min(100, Math.round(e.v / bancoTotal * 100));
    return `
    <div class="funil-row">
      <div class="funil-label">${e.l}</div>
      <div class="funil-bg">
        <div class="funil-fill" style="width:${pct}%;background:${e.c}">${pct}%</div>
      </div>
      <div class="funil-num">${e.v}</div>
    </div>`;
  }).join('');
}

// CVs por região: de onde vêm os candidatos que mandaram currículo no período escolhido (7 dias / mês atual).
// Região do candidato; sem ela, a cidade. Mostra as 8 que mais mandam.
// Entrevistas x contratações por mês (6 ou 12 meses): duas linhas suavizadas com a área pintada por baixo.
// Sai do Histórico do candidato (a planilha antiga + as entrevistas do sistema).
let mesesEntrevistasContratacoes = 6;

function setEntrevistasContratacoes(meses) {
  mesesEntrevistasContratacoes = meses;
  $$('#ec-meses button').forEach(b => b.classList.toggle('active', Number(b.dataset.meses) === meses));
  return carregarEntrevistasContratacoes();
}

// Curva suave passando por todos os pontos (Catmull-Rom convertida em Bézier)
function caminhoSuave(pts) {
  if (pts.length < 2) return '';
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    d += ` C${p1[0] + (p2[0] - p0[0]) / 6},${p1[1] + (p2[1] - p0[1]) / 6} ${p2[0] - (p3[0] - p1[0]) / 6},${p2[1] - (p3[1] - p1[1]) / 6} ${p2[0]},${p2[1]}`;
  }
  return d;
}

async function carregarEntrevistasContratacoes() {
  const el = $('#ec-grafico');
  const meses = mesesEntrevistasContratacoes;
  const { data, error } = await db.rpc('dashboard_entrevistas_contratacoes', { p_meses: meses });
  if (meses !== mesesEntrevistasContratacoes) return;      // trocou o período enquanto esperava
  if (error) { erro(el, mensagemErro(error)); return; }
  if (!data.length || data.every(r => !Number(r.entrevistas) && !Number(r.contratacoes))) {
    vazio(el, 'ti-chart-line', 'Nenhuma entrevista registrada neste período'); return;
  }

  const L = 1000, A = 260, ml = 48, mr = 24, mt = 16, mb = 30;
  const maximo = Math.max(...data.map(r => Math.max(Number(r.entrevistas), Number(r.contratacoes))), 1);
  const passo = [10, 20, 50, 100, 200, 250, 500, 1000].find(p => maximo / p <= 6) || 1000;
  const topo = Math.ceil(maximo / passo) * passo;
  const x = i => ml + (data.length === 1 ? (L - ml - mr) / 2 : i * (L - ml - mr) / (data.length - 1));
  const y = v => mt + (A - mt - mb) * (1 - v / topo);
  const MES = ['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];
  const rotulo = iso => `${MES[Number(iso.slice(5, 7)) - 1]}/${iso.slice(2, 4)}`;

  const serie = (campo, cor, nome) => {
    const pts = data.map((r, i) => [x(i), y(Number(r[campo]))]);
    const linha = caminhoSuave(pts);
    const area = `${linha} L${pts[pts.length - 1][0]},${y(0)} L${pts[0][0]},${y(0)} Z`;
    return `<path d="${area}" style="fill:${cor};fill-opacity:.12"/>
      <path d="${linha}" style="fill:none;stroke:${cor};stroke-width:2.5;stroke-linecap:round"/>
      ${pts.map((p, i) => `<circle class="ec-pt" data-i="${i}" cx="${p[0]}" cy="${p[1]}" r="5.5" style="fill:${cor}"/>`).join('')}`;
  };

  const grade = [];
  for (let v = 0; v <= topo; v += passo)
    grade.push(`<line class="linha-grade" x1="${ml}" x2="${L - mr}" y1="${y(v)}" y2="${y(v)}"/><text x="${ml - 8}" y="${y(v) + 4}" text-anchor="end">${v.toLocaleString('pt-BR')}</text>`);
  const largura = data.length === 1 ? L - ml - mr : (L - ml - mr) / (data.length - 1);
  el.innerHTML = `<div class="ec-wrap"><svg class="linha-svg" viewBox="0 0 ${L} ${A}" role="img" aria-label="Entrevistas e contratações por mês">
    ${grade.join('')}
    ${data.map((r, i) => `<text x="${x(i)}" y="${A - 8}" text-anchor="middle">${rotulo(r.mes)}</text>`).join('')}
    <line class="ec-guia" y1="${mt}" y2="${A - mb}" x1="0" x2="0"/>
    ${serie('entrevistas', 'var(--ec-entrevistas)', 'Entrevistas')}
    ${serie('contratacoes', 'var(--ec-contratacoes)', 'Contratações')}
    ${data.map((r, i) => `<rect class="ec-zona" data-i="${i}" x="${x(i) - largura / 2}" y="${mt}" width="${largura}" height="${A - mt - mb}"/>`).join('')}
  </svg><div class="ec-tip" role="status"></div></div>`;

  // Balão ao passar o mouse (ou tocar) num mês: mês + valor de cada linha, com os pontos do mês em destaque
  const svg = el.querySelector('svg'), tip = el.querySelector('.ec-tip'), guia = el.querySelector('.ec-guia');
  const mostrar = i => {
    const r = data[i];
    el.querySelectorAll('.ec-pt').forEach(c => c.classList.toggle('ativo', Number(c.dataset.i) === i));
    guia.setAttribute('x1', x(i)); guia.setAttribute('x2', x(i)); guia.style.opacity = 1;
    tip.innerHTML = `<strong>${rotulo(r.mes)}</strong>
      <div><i style="background:var(--ec-entrevistas)"></i>${Number(r.entrevistas).toLocaleString('pt-BR')}</div>
      <div><i style="background:var(--ec-contratacoes)"></i>${Number(r.contratacoes).toLocaleString('pt-BR')}</div>`;
    const px = x(i) / L, topo = y(Math.max(Number(r.entrevistas), Number(r.contratacoes))) / A;
    tip.style.left = `${px * 100}%`;
    tip.style.top = `${topo * 100}%`;
    tip.style.transform = `translate(${i === 0 ? '-12%' : i === data.length - 1 ? '-88%' : '-50%'}, calc(-100% - 12px))`;
    tip.classList.add('visivel');
  };
  const esconder = () => {
    tip.classList.remove('visivel'); guia.style.opacity = 0;
    el.querySelectorAll('.ec-pt.ativo').forEach(c => c.classList.remove('ativo'));
  };
  svg.addEventListener('pointerover', ev => { const z = ev.target.closest('.ec-zona'); if (z) mostrar(Number(z.dataset.i)); });
  svg.addEventListener('pointerleave', esconder);
}

// CVs recebidos por dia (14 dias), semana (12 semanas) ou mês (12 meses). O agrupamento é próprio do painel:
// não depende do seletor "7 dias / Mês atual" do topo.
let agruparSerieCvs = 'dia';

function setSerieCvs(agrupar) {
  agruparSerieCvs = agrupar;
  $$('#serie-agrupar button').forEach(b => b.classList.toggle('active', b.dataset.agrupar === agrupar));
  return carregarSerieCvs();
}

async function carregarSerieCvs() {
  const el = $('#serie-cvs');
  const agrupar = agruparSerieCvs;
  const { data, error } = await db.rpc('dashboard_cvs_serie', { p_agrupar: agrupar });
  if (agrupar !== agruparSerieCvs) return;                 // trocou o agrupamento enquanto esperava
  if (error) { erro(el, mensagemErro(error)); return; }

  $('#serie-sub').textContent = { dia: 'Últimos 14 dias', semana: 'Últimas 12 semanas (semana começa na segunda)', mes: 'Últimos 12 meses' }[agrupar]
    + ` · ${data.reduce((t, r) => t + Number(r.total), 0).toLocaleString('pt-BR')} no total`;
  const maior = Math.max(1, ...data.map(r => Number(r.total)));
  const rotulo = iso => {
    const [a, m, d] = iso.split('-');
    return agrupar === 'mes' ? `${['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'][m - 1]}/${a.slice(2)}` : `${d}/${m}`;
  };
  el.innerHTML = data.map((r, i) => `
    <div class="serie-col${i === data.length - 1 ? ' atual' : ''}" title="${rotulo(r.periodo)}: ${r.total} currículo(s)">
      <div class="serie-val">${r.total}</div>
      <div class="serie-barra" style="height:${Math.round(Number(r.total) / maior * 130)}px"></div>
      <div class="serie-rot">${rotulo(r.periodo)}</div>
    </div>`).join('');
}

async function carregarCvsPorRegiao() {
  const el = $('#cvs-regiao');
  const { data, error } = await db.rpc('dashboard_cvs_por_regiao', { p_dias: app.periodo });
  if (error) { erro(el, mensagemErro(error)); return; }

  $('#regiao-sub').textContent = `${app.periodo === 7 ? 'Últimos 7 dias' : 'Mês atual'} · candidatos que mandaram currículo`;
  const total = data.reduce((t, r) => t + Number(r.total), 0);
  if (!total) { vazio(el, 'ti-map-pin', 'Nenhum currículo recebido neste período'); return; }

  const topo = data.slice(0, 8);
  const linhas = topo.map(r => ({ l: r.local, v: Number(r.total), c: r.local === 'Não identificada' ? 'var(--gray-text)' : '#3B82F6' }));
  const maior = Math.max(...linhas.map(r => r.v));
  el.innerHTML = linhas.map(r => `
    <div class="funil-row">
      <div class="funil-label" style="width:150px" title="${escapeHtml(r.l)}">${escapeHtml(r.l)}</div>
      <div class="funil-bg"><div class="funil-fill" style="width:${Math.max(4, Math.round(r.v / maior * 100))}%;background:${r.c}">${Math.round(r.v / total * 100)}%</div></div>
      <div class="funil-num" style="width:48px">${r.v.toLocaleString('pt-BR')}</div>
    </div>`).join('');
}

// Vagas abertas: todas, as mais antigas primeiro (são as que mais precisam de atenção), com o andamento de cada uma.
async function carregarVagasResumo() {
  const { data, error } = await db.from('vw_vagas_resumo')
    .select('*').order('dias_aberta', { ascending: false });

  const el = $('#vagas-resumo');
  if (error) { erro(el, error.message); $('#m-vagas').textContent = '—'; return; }

  const setores = new Set(data.map(v => v.setor_nome)).size;
  const posicoes = data.reduce((t, v) => t + (v.quantidade || 1), 0);
  $('#m-vagas').textContent = data.length;
  $('#m-vagas-lbl').textContent = data.length
    ? `Vagas abertas · ${setores} ${setores === 1 ? 'setor' : 'setores'}${posicoes !== data.length ? ` · ${posicoes} ${posicoes === 1 ? 'vaga pendente' : 'vagas pendentes'}` : ''}` : 'Vagas abertas';

  if (!data.length) {
    vazio(el, 'ti-briefcase', 'Nenhuma vaga aberta',
      'Cadastre uma vaga para atribuir candidatos do Banco de Talentos');
    return;
  }

  // Vaga que vale para todas as lojas de sempre mostra só "Todas" (lojas fora do padrão, como a Capital, continuam citadas)
  const lojasDaVaga = texto => {
    const siglas = String(texto || '').split(' · ').filter(Boolean);
    const padrao = (app.cache.empresas || []).filter(e => e.padrao_distancia).map(e => e.sigla);
    if (!siglas.length) return '—';
    if (!padrao.length || !padrao.every(x => siglas.includes(x))) return siglas.join(' · ');
    const extras = siglas.filter(x => !padrao.includes(x));
    return extras.length ? `Todas + ${extras.join(' · ')}` : 'Todas';
  };
  const dias = n => n === 0 ? 'hoje' : `${n} dia${n > 1 ? 's' : ''}`;
  el.innerHTML = `<table>
    <thead><tr><th>Vaga</th><th>Lojas</th><th>Aberta há</th><th>A contratar</th><th>Atribuídos</th><th>Entrevistas</th><th>Contratados</th><th>No banco (setor)</th></tr></thead>
    <tbody>${data.map(v => `
      <tr style="cursor:pointer" onclick="irPara('vagas')">
        <td><div style="display:flex;align-items:center;gap:9px">
          <span class="vaga-mini-icon" style="width:30px;height:30px;font-size:15px;background:${v.setor_cor}1a;color:${v.setor_cor}"><i class="ti ${v.setor_icone}"></i></span>
          <div><div style="font-weight:600">${escapeHtml(v.titulo)}</div><div class="exc-meta">${escapeHtml(v.setor_nome)}</div></div></div></td>
        <td>${escapeHtml(lojasDaVaga(v.empresas))}</td>
        <td>${dias(v.dias_aberta)}</td>
        <td>${v.quantidade || 1}</td>
        <td>${v.total_candidatos}</td>
        <td>${v.total_entrevistas}</td>
        <td>${v.total_contratados}</td>
        <td>${v.compativeis_no_banco}</td>
      </tr>`).join('')}
    </tbody></table>`;
}

async function carregarExcecoesResumo() {
  const { data, error } = await db.from('excecoes')
    .select('email_remetente,tipo,recebido_em')
    .eq('status', 'pendente')
    .order('recebido_em', { ascending: false }).limit(3);

  const el = $('#excecoes-resumo');
  if (error) { erro(el, error.message); return; }
  if (!data.length) {
    vazio(el, 'ti-circle-check', 'Nenhuma exceção pendente');
    return;
  }

  const ICONES = {
    sem_anexo:'ti-mail-off', formato_invalido:'ti-file-x',
    arquivo_corrompido:'ti-file-x', ocr_falhou:'ti-scan',
    docs_privado:'ti-lock', nao_e_curriculo:'ti-file-off',
    vaga_nao_identificada:'ti-help-circle', erro_processamento:'ti-alert-triangle'
  };
  const LABELS = {
    sem_anexo:'Sem currículo', formato_invalido:'Formato inválido',
    arquivo_corrompido:'Sem leitura', ocr_falhou:'OCR falhou',
    docs_privado:'Docs privado', nao_e_curriculo:'Não é currículo',
    vaga_nao_identificada:'Vaga indefinida', erro_processamento:'Erro'
  };

  el.innerHTML = data.map(e => `
    <div class="exc-row">
      <i class="ti ${ICONES[e.tipo]||'ti-alert-triangle'}" style="color:var(--yellow);font-size:17px"></i>
      <div style="flex:1;min-width:0">
        <div class="exc-email">${escapeHtml(e.email_remetente)}</div>
        <div class="exc-meta">${tempoRelativo(e.recebido_em)} · ${LABELS[e.tipo]||e.tipo}</div>
      </div>
      <span class="pill pill-yellow">${LABELS[e.tipo]||e.tipo}</span>
    </div>`).join('');
}

function setPeriodo(p) {
  app.periodo = p;
  $('#btn7').classList.toggle('active', p === 7);
  $('#btn30').classList.toggle('active', p === 30);
  carregarDashboard();
}


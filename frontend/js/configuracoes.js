// ═══════════════════════════════════════════════════════════
//  CONFIGURAÇÕES (somente administrador)
// ═══════════════════════════════════════════════════════════

async function carregarConfig() {
  const el = $('#config-lista');
  loading(el);

  const { data, error } = await db.from('configuracoes').select('*').order('chave');
  if (error) { erro(el, error.message); return; }

  const GRUPOS = {
    'Banco de Talentos — sanitização': ['sanitizacao_intervalo_meses','sanitizacao_meses_sem_movimentacao','sanitizacao_reprovacoes_max',
      'sanitizacao_aderencia_min','sanitizacao_confianca_min','sanitizacao_detectar_duplicidade','sanitizacao_retencao_maxima_meses',
      'sanitizacao_adiar_meses','sanitizacao_pesos','sanitizacao_emails_aviso'],
    'Avaliação por IA':  ['ia_confianca_minima','faixa_ambigua_min','faixa_ambigua_max','modelo_ia_classificacao','modelo_ia_avaliacao'],
    'Captação de e-mail':['horario_execucao_pipeline','imap_servidor','imap_porta','tamanho_minimo_anexo_bytes'],
    'WhatsApp':          ['mensagem_convocacao_padrao','ddi_padrao','ddd_padrao']
  };

  el.innerHTML = Object.entries(GRUPOS).map(([grupo, chaves]) => {
    const itens = data.filter(c => chaves.includes(c.chave));
    if (!itens.length) return '';
    // Liga/desliga da segunda avaliação: grava as duas faixas (vazias = desativada)
    const temFaixa = FAIXA_SEGUNDA.every(k => itens.some(c => c.chave === k));
    const interruptor = temFaixa ? `
        <div class="config-item">
          <div class="config-info">
            <div class="config-chave">segunda_avaliacao</div>
            <div class="config-desc">Reavalia de forma independente as notas dentro da faixa abaixo. Desativada, cada currículo é avaliado uma vez só (gasta menos). Liga/desliga as duas faixas.</div>
          </div>
          <label class="config-toggle">
            <input type="checkbox" id="cfg-segunda-ativa"
                   onchange="alternarSegundaAvaliacao(this.checked)"> Ativa
          </label>
        </div>` : '';
    return `<div class="config-grupo">
      <h3>${grupo}</h3>
      ${interruptor}
      ${itens.map(c => {
        const valor = typeof c.valor === 'string' ? c.valor : JSON.stringify(c.valor);
        const ehModelo = CHAVES_MODELO.includes(c.chave);
        const controle = ehModelo
          ? `<select class="config-input" id="cfg-${c.chave}" onchange="atualizarEstimativas()">${opcoesModelo(valor, c.chave)}</select>`
          : `<input class="config-input" id="cfg-${c.chave}" value='${escapeHtml(valor)}'>`;
        return `
        <div class="config-item">
          <div class="config-info">
            <div class="config-chave">${c.chave}</div>
            <div class="config-desc">${escapeHtml(c.descricao||'')}</div>
            ${ehModelo ? `<div class="config-est" id="est-${c.chave}"></div>` : ''}
          </div>
          ${controle}
          <button class="btn-sm azul" onclick="salvarConfig('${c.chave}')">Salvar</button>
        </div>`;
      }).join('')}
      ${CHAVES_MODELO.every(k => itens.some(c => c.chave === k)) ? '<div class="config-total" id="est-total"></div>' : ''}
    </div>`;
  }).join('');
  sincronizarSegundaAvaliacao();
  await carregarNiveisConfig(el);
}

// ── Níveis da qualificação dos currículos ──
// O administrador habilita/desabilita Jovem Aprendiz e Trainee (para auditar a classificação) e reescreve o critério de qualquer
// nível. Desabilitado: a IA deixa de receber o nível e o formulário da vaga deixa de oferecê-lo; o que já o tem continua como está.
// Cada mudança fica na auditoria (alterar_nivel_funcao, backend/sql/036). Júnior, Pleno e Sênior não desabilitam.
async function carregarNiveisConfig(el) {
  const { data, error } = await db.from('niveis_funcao').select('codigo,nome,descricao,ativo,ordem').order('ordem');
  if (error || !data?.length) return;
  el.insertAdjacentHTML('beforeend', `<div class="config-grupo" id="config-niveis">
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
const PARTE_EM_SEGUNDA_AVALIACAO = 0.35;   // fatia estimada dos currículos com nota na faixa
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
  const comSegunda = chave === 'modelo_ia_avaliacao' && segundaAvaliacaoAtiva();
  return porChamada * (comSegunda ? 1 + PARTE_EM_SEGUNDA_AVALIACAO : 1);
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
    const extra = k === 'modelo_ia_avaliacao' && segundaAvaliacaoAtiva() ? ' (inclui a segunda avaliação)' : '';
    el.textContent = `${m.nome}: ${usd(m.entrada)} entrada / ${usd(m.saida)} saída por 1M tokens · ` +
      `≈ ${usd(c)} por currículo${extra} · ${usd(c * 100)} a cada 100`;
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

const FAIXA_SEGUNDA = ['faixa_ambigua_min', 'faixa_ambigua_max'];

// Ativa = as duas faixas são números; qualquer uma vazia desativa (o backend segue a mesma regra)
function segundaAvaliacaoAtiva() {
  return FAIXA_SEGUNDA.every(k => {
    const v = $(`#cfg-${k}`)?.value.trim();
    return v !== undefined && v !== '' && !isNaN(Number(v));
  });
}

function sincronizarSegundaAvaliacao() {
  const chk = $('#cfg-segunda-ativa');
  if (chk) chk.checked = segundaAvaliacaoAtiva();
  atualizarEstimativas();   // a segunda avaliação muda o custo estimado
}

async function gravarConfig(chave, valor) {
  const { error } = await db.from('configuracoes')
    .update({ valor, updated_by: app.usuario.id }).eq('chave', chave);
  return error;
}

async function salvarConfig(chave) {
  const raw = $(`#cfg-${chave}`).value;
  let valor;
  try { valor = JSON.parse(raw); }
  catch { valor = raw; }

  const error = await gravarConfig(chave, valor);
  toast(error ? error.message : 'Configuração salva', error ? 'erro' : 'ok');
  sincronizarSegundaAvaliacao();
}

async function alternarSegundaAvaliacao(ativa) {
  const [min, max] = FAIXA_SEGUNDA.map(k => $(`#cfg-${k}`));
  if (ativa) {
    // volta para a faixa que estava antes de desativar (nesta sessão) ou para o padrão
    min.value = min.dataset.anterior || '60';
    max.value = max.dataset.anterior || '75';
  } else {
    min.dataset.anterior = min.value;
    max.dataset.anterior = max.value;
    min.value = '';
    max.value = '';
  }
  const valorDe = el => el.value.trim() === '' ? '' : Number(el.value);
  const erros = await Promise.all([
    gravarConfig(FAIXA_SEGUNDA[0], valorDe(min)),
    gravarConfig(FAIXA_SEGUNDA[1], valorDe(max))
  ]);
  const erro = erros.find(Boolean);
  toast(erro ? erro.message : (ativa ? 'Segunda avaliação ativada' : 'Segunda avaliação desativada'),
        erro ? 'erro' : 'ok');
  if (erro) carregarConfig();   // não deixa a tela mostrar um estado que o banco não tem
  else sincronizarSegundaAvaliacao();
}


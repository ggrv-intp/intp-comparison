# Reunião com Prof. De Rose -- 2026-05-04

**Mestrando:** André Sacilotto Santos (PPGCC/PUCRS)
**Status do trabalho:** Fase experimental em curso, campanha multi-variante em execução no Hetzner

---

## TL;DR (1 minuto)

1. **6 variantes implementadas e funcionais** (V1..V6), cobrindo o espectro
   SystemTap → procfs → bpftrace → eBPF/CO-RE.
2. **LAD pantanal01 não suporta a metodologia em sua íntegra** — confirmado
   empiricamente hoje: hardware Skylake-SP gen1 não expõe RDT monitoring,
   bloqueando `llcocc` para qualquer variante. Migração para Hetzner foi
   tecnicamente forçada, não preferência.
3. **V2 e V3 (SystemTap modernizado) apresentam fragilidade quantificada** —
   sample loss seletivo, blk overflow corrigido, e dois incidentes de
   deadlock kernel-side documentados. v4-v6 não conseguem chegar nesse
   modo de falha por construção do framework.
4. **Campanha grande em execução no Hetzner** — V2 completou solo (60 runs
   limpos), V3 em curso, V4-V6 ainda na fila. ETA: ~20h.
5. **Três decisões para o orientador hoje** -- ver Seção 6.

---

## 1. Contexto (1 min)

O paper IntP de Xavier et al. (SBAC-PAD 2022, PUCRS) propôs uma metodologia
para **quantificar interferência entre aplicações co-localizadas em
servidores compartilhados**, baseada em sete métricas coletadas via
instrumentação de SO (SystemTap):

| Recurso compartilhado | Métricas IntP |
|---|---|
| CPU | `cpu` |
| Cache LLC | `llcmr`, `llcocc` |
| Banda de memória | `mbw` |
| Block I/O | `blk` |
| Rede | `netp`, `nets` |

A pergunta de pesquisa desta dissertação:

> *"Como tecnologias modernas de instrumentação se comparam para profiling
> de interferência em kernels pós-6.8, sob critérios de fidelidade,
> sobrecarga, portabilidade e risco operacional?"*

Não é replicar o paper original. É **validar a metodologia em sistemas
modernos** e mapear o trade-off entre as opções tecnológicas hoje
disponíveis.

---

## 2. As seis variantes implementadas

Cada variante representa um ponto distinto no espectro framework × kernel
× risco operacional. **Não existe "a melhor" — cada uma faz um trade-off
diferente.**

### Família 1 -- IntP histórico

**V1.** IntP original sem modificação. SystemTap, kernel <=6.6.
Serve como **referência de fidelidade**: qualquer outra variante precisa
concordar com V1 dentro de margem aceitável quando rodada nos mesmos
workloads.

### Família 2 -- SystemTap modernizado (V2 e V3)

Existem **duas variantes SystemTap em kernel 6.8+** porque cada uma isola
uma variável diferente.

**V2.** SystemTap com patch mínimo de compatibilidade -- removido apenas
o acesso ao campo `task_struct->cqm_rmid` que sumiu em 6.8. Cobertura:
6/7 métricas (`llcocc` retorna zero).

**V3.** V2 + integração com resctrl (interface estável do kernel para
RDT). Helper daemon mantém mon_groups, lê `llc_occupancy`, expõe via
arquivo lido por embedded C dentro do stap. Cobertura: 7/7 métricas.

**Por que rodar V2 e V3 juntos:** comparar V2 vs V3 isola o **custo da
camada resctrl-helper**. Se a fragilidade for igual em ambos, é do
framework SystemTap. Se V3 for mais frágil, é do helper. Sem rodar V2,
essa atribuição é impossível. **V2 não é redundância — é controle
experimental.**

### Família 3 -- Saída do framework SystemTap

**V4.** procfs + perf_event_open + resctrl. Pure userspace, sem módulo
de kernel, sem debuginfo. Caminho mais conservador.

**V5.** bpftrace + resctrl. eBPF via linguagem de alto nível.

**V6.** eBPF/CO-RE + libbpf + resctrl. eBPF cru com bibliotecas de baixo
nível. Maior controle, melhor performance.

### Matriz comparativa

| Var | Framework | Kernel | Risco operacional | Cobertura | Status |
|-----|---|---|---|---|---|
| V1 | SystemTap | 4.x-5.x | Alto (módulo) | 7/7 | Reproduzido |
| V2 | SystemTap (patch min) | >=6.8 | Alto | 6/7 | Validado em campanha |
| V3 | SystemTap + resctrl | >=6.8 | Alto | 7/7 | Validado em campanha |
| V4 | procfs+perf+resctrl | >=4.10 | Baixo | 7/7 | Implementado |
| V5 | bpftrace+resctrl | >=5.8 | Médio | 7/7 | Implementado |
| V6 | eBPF/CO-RE+libbpf+resctrl | >=5.8 | Baixo-médio | 7/7 | Implementado |

---

## 3. Achados empíricos da fase 1

### Achado A -- LAD pantanal01 não suporta `llcocc` em hardware

Verificação executada hoje (04/05/2026) em pantanal01:

- **CPU:** Intel Xeon Gold 5118 (Skylake-SP gen1), stepping 4, microcode 0x2007006
- **Kernel:** 5.15.0-163-generic
- **CPUID anuncia:** `cqm`, `cqm_llc`, `cqm_occup_llc`, `cqm_mbm_total`,
  `cqm_mbm_local`, `cat_l3`, `mba`, `rdt_a` (RDT completo)
- **Realidade do kernel:**

```
$ sudo dmesg | grep -i resctrl
[    4.402824] resctrl: MB allocation detected

$ ls /sys/fs/resctrl/info/L3_MON/
ls: cannot access ... No such file or directory
```

**Apenas MBA detectada. CMT/MBM monitoring desativados pelo kernel** apesar
das flags de CPUID. Causa atribuível a errata documentada de Skylake-SP gen1
e/ou degradação por microcódigo posterior a mitigações Spectre/MDS.

**Impacto:** `llcocc` não pode ser coletada por nenhuma variante neste
hardware. Cobertura máxima em pantanal01 = 6/7 métricas.

**Decorrência:** a migração para Hetzner (Sapphire Rapids) não foi
preferência institucional — foi imposta pela necessidade de hardware com
RDT monitoring **ativado em produção**. Sapphire Rapids é a primeira
geração Intel onde isso é confiável.

Documento detalhado: `bench/findings/lad-skylake-sp-rdt-monitoring-disabled.md`.

### Achado B -- Deadlock kernel-side em SystemTap V3 (ocorrência #1)

Data: 2026-05-03, primeira campanha grande no Hetzner.

Sintomas:
- 2 processos `stapio` e 1 `stress-ng` em D-state (uninterruptible sleep)
- WCHAN: `wait_r` (kernel completion)
- ELAPSED: 47-49 minutos sem mover
- Recovery tentado e falhado: `kill -9`, `pkill -KILL stapio`,
  `rmmod -f stap_<hash>` (refused com EAGAIN, refcount=1)
- **Solução possível: reboot. Não há recovery em userspace.**

Documento detalhado: `bench/findings/v3-modernization-reliability-findings.md`,
Finding #5.

### Achado C -- Deadlock kernel-side em SystemTap V3 (ocorrência #2)

Data: 2026-05-04, campanha grande em execução (post-patches).

Mesmo failure mode, **mesmo workload** (`app01_ml_llc` rep=2 — pressão LLC),
condições controladas:
- Kernel limpo após reboot
- Patch de cleanup pre-run (V2+V3) aplicado
- Patch de blk overflow guard aplicado
- Governor `performance` ativo

Bench script desta vez **não travou** -- logou WARN, escalou para SIGKILL,
não conseguiu reaper, e seguiu para próximo workload. Acumulação de
módulos contida (~2 leftover).

**Significado:** failure mode é **reproduzível e workload-correlated**.
Não é incidente isolado — é assinatura sistemática de fragilidade do
framework SystemTap em kernel 6.8+ sob pressão de cache LLC.

### Achado D -- Sample loss seletivo por classe de workload

Extrator de fragilidade rodado sobre smoke V2 (2026-05-03):

```
Per-variant fragility (env=bare, V2 solo+pairwise+overhead+timeseries)
  variant  runs  mean_loss%  max_loss%   skipped  fatals  errors
  v2        41        9.69      60.00          0       0       0
```

**Mean loss 9.69%, max 60% — concentrado em workloads de rede:**

| Workload | Sample loss observado | Classe |
|---|---|---|
| `cpu_v_cache` rep1/2 | 0% | CPU+LLC |
| `disk_v_disk` rep1/2 | 0-2% | Disco |
| `stream_v_stream` rep1/2 | 0% | Memória |
| `app01..09` (ML/streaming) | <5% | LLC/MBW/CPU |
| `app13..15` (query/disk) | <5% | Block I/O |
| `app11_sort_net` rep1 | 43% | **Rede** |
| `app11_sort_net` rep2 | 35% | **Rede** |
| `app12_sort_net` rep1 | **60%** | **Rede** |
| `net_v_net` rep2 | **58%** | **Rede** |

**Conclusão:** fragilidade tem assinatura. Probes de network stack
(napi_complete_done, __napi_schedule_irqoff — Sec. IV.B do paper IntP)
foram particularmente afetadas pelas mudanças de API entre kernel 5.x
e 6.8. **Probes de outras subsistemas funcionam estavelmente.**

### Achado E -- blk overflow nativo do código IntP (corrigido)

Após primeiro smoke V2 completo, agregados reportaram valores absurdos
em `blk`:

```
ref_stream     blk = -3.260.448.013     (esperado: 0-99)
ref_cpu        blk = -10.488.140.212
ref_disk       blk = -19.097.849.328
mixed_long     blk = -23.210.883.712
```

**Causa:** em kernel 6.8+, `$rq->io_start_time_ns` pode estar em domain
de relógio diferente de `local_clock_ns()`, produzindo deltas nonsense
que overflowam multiplicações int64 downstream.

**Mitigação:** filtro inline no probe (`0 < delta < 10s`) + clamp
`util ∈ [0,99]` em `print_block_report`. Solução já presente no V3 desde
sua implementação inicial; **retro-portada para V2** em 2026-05-04.

Arquivo: `v2-updated/intp-6.8.stp:182-193, 199-224`.

---

## 4. Patches de mitigação aplicados (resposta a problemas reais)

| Patch | Arquivo | Justificativa empírica |
|---|---|---|
| Cleanup `stap_deep_cleanup` pre-run estendido para V2 | `bench/run-intp-bench.sh:882` | V2 acumulava módulos leftover quando primeiro variant da batelada |
| blk overflow guard retro-portado de V3 para V2 | `v2-updated/intp-6.8.stp:182-193,199-224` | Achado E |
| Extrator estruturado de fragilidade | `bench/plot/extract-fragility.py` | Substrato para `fragility-summary.tsv` por campanha; alimenta seção quantitativa da tese |

Cada patch é evidência de uma fragilidade que precisou ser endereçada para
que a campanha funcionasse. **Patches mitigam, não eliminam.** Continuam
acontecendo deadlocks ocasionais (Achado C) que só V4-V6 conseguem evitar
por construção.

---

## 5. Estado da campanha grande (snapshot ao vivo)

**Comando ativo no Hetzner:**

```bash
sudo BENCH_VARIANTS=v2,v3,v4,v5,v6  BENCH_ENVS=bare \
     DURATION=120  REPS=4  INTERVAL=1 \
     WARMUP=15  COOLDOWN=10 \
     TIMESERIES_DURATION=600  OVERHEAD_DURATION=60 \
     RUN_HIBENCH=1  HIBENCH_SIZE=medium  HIBENCH_PROFILE=both \
     INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
     bash run-big-batch.sh
```

**Progresso (último check, 04:21):**
- V2 solo: **60/60 runs** (completo)
- V3 solo: 2/60 runs concluídos; hit deadlock no `app01_ml_llc` rep=2 (Achado C)
- V4/V5/V6 solo: pendentes
- Pairwise/overhead/timeseries (todos os variants): pendentes
- HiBench: pendente
- ETA total: ~20h, finalizando 5/5 no fim do dia

### 5.1 Por que V3 trava: caracterização do failure mode

O comportamento observado sob carga sustentada em V3:

1. **Sob alta pressão de probes**, um handler entra em uma função do
   kernel que detém um lock compartilhado (ex: scheduler runqueue lock).
   Outros CPUs que precisam do mesmo lock entram em espera bloqueante.
2. **Os processos afetados ficam em D-state** com `WCHAN=wait_r` (kernel
   completion). SIGKILL não é entregue até o thread voltar para userspace;
   o thread não volta porque está bloqueado em completion; a completion
   não chega.
3. **O módulo SystemTap fica refcount-locked** -- `stapio` ainda tem o
   módulo aberto, `rmmod -f` falha com `EAGAIN`.
4. **Não há recovery em userspace.** A única saída é reboot.

A combinação destes quatro elementos -- handler kernel-side capaz de
bloquear, ausência de mecanismo de timeout em probes, refcount imobilizando
o módulo, e impossibilidade de SIGKILL atingir D-state -- é estrutural ao
framework SystemTap. Variantes baseadas em eBPF (V5, V6) não podem chegar
a este estado por construção: o verificador formal rejeita programas que
não terminam, e não há módulo de kernel para travar refcount.

### 5.2 Mitigações aplicadas ao caminho V2/V3

Cinco intervenções foram aplicadas ao longo da fase experimental.
**Mitigações reduzem probabilidade de cascata, mas não eliminam o failure
mode estrutural** descrito em 5.1 -- por isso V4-V6 são necessárias.

| Intervenção | Arquivo | Efeito |
|---|---|---|
| `stap_deep_cleanup` pre-run estendido para V2+V3 | `bench/run-intp-bench.sh:882` | Antes de cada run, descarrega módulos stap leftover do run anterior. Evita que o segundo run da mesma campanha falhe ao registrar `intestbench` no procfs. |
| Pausa profunda periódica (`INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5`) | `bench/run-intp-bench.sh:884` | A cada 5 runs, sleep adicional de 8s para o kernel reclamar recursos antes de carregar novo módulo. |
| Flag `--suppress-handler-errors` + `-DMAXSKIPPED=1000000` | `bench/run-intp-bench.sh:902-906` | Stap não aborta quando handlers individuais falham; tolerância elevada para probes saltadas. |
| Filtro defensivo + clamp `[0,99]` na métrica `blk` | `v2-updated/intp-6.8.stp:182-193,199-224` | Resolve overflow numérico do `blk` (Achado E), retro-portado de V3 que já tinha o guard. |
| Resolução de comm-name resiliente para alvos do stap | `bench/run-intp-bench.sh:898-915` | Aguarda exec do wrapper bash antes de resolver comm; jamais permite que o alvo seja `bash`/`sh`. Garante que o probe foque no workload, não no orquestrador. |

**Quando a cascata acontece mesmo assim:** o bench script loga WARN,
escala para SIGKILL (sem efeito em D-state), desiste do PID, e
**continua para o próximo run**. A campanha não trava -- apenas acumula
1-2 módulos leftover por evento. Custo prático: ~60s extras por
ocorrência + desperdício de uma rep.

### 5.3 O que falta executar na campanha atual

Assumindo que a campanha continue progredindo no ritmo observado:

| Estágio / Variante | Runs restantes | Tempo estimado |
|---|---|---|
| V3 solo (workloads 2-15) | 56 runs × ~150s + ~3-5 deadlocks × 60s extra | ~2.5-3h |
| V4 solo | 60 runs × ~135s | ~2.3h |
| V5 solo | 60 runs × ~135s | ~2.3h |
| V6 solo | 60 runs × ~135s | ~2.3h |
| Pairwise (todos variants) | 5 pares × 4 reps × 5 vars = 100 runs | ~4h |
| Overhead (todos variants) | 3 refs × 4 reps × 5 vars + 3 baselines × 4 = 72 runs | ~1.5h |
| Timeseries (todos variants) | 1 × 5 vars × 600s | ~1h |
| HiBench Spark subset | ~5 workloads × 5 vars × 1 rep | ~3-4h |
| Plots + report | -- | ~5min |

**Total estimado restante: ~17-20h.** A campanha está dentro do envelope
previsto.

### 5.4 Comandos para após a campanha (ou para retomar caso ela morra)

**Se a campanha continuar saudável até o fim:**

```bash
# Pós-processamento — extrair fragilidade + gerar pipeline IADA
RESULT=/root/intp/results/LATEST-BIG/bench-full

# 1) Métricas de fragilidade estruturadas
sudo python3 bench/plot/extract-fragility.py "$RESULT"

# 2) Conversão IntP -> Meyer/IADA
sudo python3 bench/convert-profiler-to-meyer.py "$RESULT" \
     --stage solo --output-root "$RESULT/meyer" \
     --manifest "$RESULT/meyer/manifest.tsv"

# 3) Árvore CloudSim/IADA (focada em V4-V6 que são as variantes "limpas")
sudo python3 bench/generate-iada-tree.py \
     --manifest "$RESULT/meyer/manifest.tsv" \
     --out-root "$RESULT/iada-tree" \
     --variant v4 --variant v5 --variant v6 --stage solo

# 4) Plots padrão (10 figuras da tese)
sudo python3 bench/plot/plot-intp-bench.py "$RESULT"
```

**Se a campanha morrer no meio (deadlock cascata, OOM, ou crash):**
o script `run-big-batch.sh` suporta retomada idempotente via `RESUME_DIR`.
Ele detecta `profiler.tsv` com samples e pula esses runs:

```bash
# Retomada da mesma campanha (substituir <TS> pelo timestamp atual)
RESUME=/root/intp/results/big-batch-<TS>

# Limpeza preventiva antes de relançar (sem reboot, em ambiente saudável)
pkill -KILL -f stapio 2>/dev/null
lsmod | awk '/^stap_/{print $1}' | xargs -r -n1 rmmod -f
bash /root/intp/shared/intp-resctrl-helper.sh stop 2>/dev/null

# Relançar dentro do mesmo tmux (ou novo)
tmux new -s intp-resume
cd /root/intp
sudo \
  BENCH_VARIANTS=v2,v3,v4,v5,v6  BENCH_ENVS=bare \
  DURATION=120  REPS=4  INTERVAL=1 \
  WARMUP=15  COOLDOWN=10 \
  TIMESERIES_DURATION=600  OVERHEAD_DURATION=60 \
  RUN_HIBENCH=1  HIBENCH_SIZE=medium  HIBENCH_PROFILE=both \
  RUN_PLOTS=1 \
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
  RESUME_DIR="$RESUME" \
  bash run-big-batch.sh
```

**Se decidirmos cutoff de V3 (Decisão 1, opção c):** rodar campanha
separada apenas para V4-V6, descartando o que falta de V3:

```bash
# Variantes "limpas" — sem SystemTap, sem risco de deadlock
tmux new -s intp-clean
cd /root/intp
sudo \
  BENCH_VARIANTS=v4,v5,v6  BENCH_ENVS=bare \
  DURATION=120  REPS=4  INTERVAL=1 \
  WARMUP=15  COOLDOWN=10 \
  TIMESERIES_DURATION=600  OVERHEAD_DURATION=60 \
  RUN_HIBENCH=1  HIBENCH_SIZE=medium  HIBENCH_PROFILE=both \
  RUN_PLOTS=1 \
  bash run-big-batch.sh
```

ETA dessa campanha enxuta: ~10-12h, sem risco de cascata.

---

## 6. Decisões para o orientador

### Decisão 1 -- Cutoff de SystemTap

V2 e V3 funcionam com fragilidade quantificada e dois incidentes de deadlock
reproduzíveis. Três opções:

- **(a) Manter ambos, com cobertura parcial declarada.** Reportar como
  evidência empírica do limite da metodologia legada em kernel 6.8+.
  Requer aceitar que algumas runs vão ser inválidas em workloads de rede.
- **(b) Manter apenas V3, declarar V2 como passo intermediário documentado.**
  Reduz uma variante na comparação numérica; preserva V2 como artefato
  metodológico (controle experimental sobre o helper resctrl).
- **(c) Cutoff total de SystemTap modernizado.** V1 fica como referência
  histórica (Ubuntu 22 / kernel 5.15); V2/V3 viram apêndice de
  "tentativa documentada de modernização SystemTap"; foco quantitativo
  fica em V4-V6.

**Recomendação do mestrando:** opção (a). Os achados B/C/D são valor
direto para a tese e a defesa.

### Decisão 2 -- Vencedor narrativo entre V4-V6

Após coleta completa, qual variante moderna ocupa o papel de "vencedor"
na conclusão?

- V4 tende a ter menor overhead, maior portabilidade (procfs em qualquer kernel)
- V6 tende a ter melhor fidelidade (eBPF acessa eventos kernel-side)
- V5 fica no meio (bpftrace mais ergonômico que V6, mas menos performance)

**Pergunta:** privilegiamos overhead (V4), fidelidade (V6), ou apresentamos
sem hierarquia ("cada um para um caso")?

### Decisão 3 -- Venue de submissão

- **SBAC-PAD 2026 (Madrid, Qualis A4):** casa do paper original, comunidade
  alinhada, deadline mais cedo.
- **IISWC 2026 (Boulder, CORE B):** mais adequado para comparação
  multi-variante, peer-reviewers tipicamente vêm de instrumentação/eBPF.

---

## 7. Plano até a defesa parcial

| Semana | Entrega |
|---|---|
| 1-2 | Conclusão da campanha big-batch + extração de fragilidade |
| 3-4 | 10 plots padrão (fig01..fig08) gerados a partir do dataset versionado |
| 5-6 | Análise cross-environment + identificação do envelope de segurança operacional |
| 7-8 | Capítulos 4 e 5 da dissertação em revisão |

Critérios objetivos de encerramento da fase experimental:
- Todos os 10 plots padrão gerados a partir de dataset versionado
- Tabela 5.x preenchida com números para 5 dimensões × 6 variantes
- Reprodução do experimento V4 em ambiente Hetzner para validar transferibilidade
- Capítulos 4 e 5 em revisão antes de submission

---

## 8. Apêndice -- Por que estes workloads/parâmetros

### Workloads (15 microbenchmarks via stress-ng + 5 pares + 3 refs overhead)

Cobertura sistemática dos 5 eixos de pressão do paper IntP, com 2-3
representantes por eixo (replicação dentro do eixo = validação cruzada):

| Eixo | Workloads representativos |
|---|---|
| LLC | app01-app03 (ml_llc) |
| LLC + MBW | app04-app05 (streaming) |
| Memória | app06-app07 (ordering) |
| CPU + Memória | app08-app09 (classification) |
| CPU puro | app10 (search) |
| Rede | app11-app12 (sort_net) |
| Disco | app13-app15 (query_*) |

stress-ng escolhido porque: (1) presente em todas distros principais com
mesmo binário, (2) reporta throughput numérico via `--metrics-brief` para
cruzar com profiler, (3) timeout exato para reprodutibilidade.

HiBench medium (subset): wordcount, terasort, kmeans, pagerank — mesmas
categorias dos estudos de caso do paper IntP, ground truth realista.

### Parâmetros

| Parâmetro | Valor | Justificativa |
|---|---|---|
| DURATION | 120s | >= 30s exigido por IADA; 4+ ciclos de cache; janela de scheduling realista |
| REPS | 4 | Mapeamento direto com `generate-iada-tree.py` (rep1=inc, rep2=dec, rep3=osc, rep4=con) |
| INTERVAL | 1s | Granularidade do paper original |
| WARMUP | 15s | Cache atinge regime + JIT JVM aquece + stap registra probes |
| COOLDOWN | 10s | TIME_WAIT de sockets, page cache evict, cleanup de módulo |
| TIMESERIES_DURATION | 600s | Janela longa para detectar transientes |
| OVERHEAD_DURATION | 60s | Janelas curtas reduzem variância térmica entre baseline e profilado |
| HIBENCH_SIZE | medium | Small fica em RAM; large >1h/workload; medium estressa MBW+disco realisticamente |

---

## 9. Artefatos e rastreabilidade

| Artefato | Localização |
|---|---|
| Código V1 (SystemTap original) | `v1-original/` |
| Código V2 (V1 sem llcocc) | `v2-updated/` |
| Código V3 (V2 + resctrl) | `v3-updated-resctrl/` |
| Código V4 (procfs+perf+resctrl) | `v4-hybrid-procfs/` |
| Código V5 (bpftrace+resctrl) | `v5-bpftrace/` |
| Código V6 (eBPF/CO-RE+libbpf) | `v6-ebpf-core/` |
| Findings | `bench/findings/*.md` |
| Logs de campanha Hetzner | `results/big-batch-<ts>/` |
| Diagnóstico LAD pantanal01 | `lad-diagnostic-pantanal01-20260504_133606.txt` |

Documentos de findings que sustentam a defesa parcial:
- `lad-skylake-sp-rdt-monitoring-disabled.md` (NOVO, 04/05/2026)
- `v3-modernization-reliability-findings.md` (deadlock #1 documentado)
- `v1-baseline-failure-diagnosis.md`

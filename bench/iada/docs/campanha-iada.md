# Campanha IADA -- Experimento de escalonamento (segunda fase)

**Status:** scaffold pronto, smoke test validado em 2026-05-05
**Hospedeiro:** local (laptop) -- CloudSim é simulação determinística
**Dataset original validado:** 192 apps em 48 PMs, 24 intervalos, IDI médio 3476.2

---

## Objetivo científico

Testar a hipótese central:

> **Perfis de interferência coletados com instrumentação de maior fidelidade
> produzem decisões de escalonamento de melhor qualidade?**

A campanha IntP varia a *fonte* dos perfis (V0-V3 × bare/container/vm).
Esta campanha alimenta cada conjunto de perfis no **mesmo** scheduler
(IADA SAO + classificador SVM treinado em stressors sintéticos), isolando
a fidelidade da instrumentação como variável independente.

---

## Arquitetura validada

```
intp/results/big-batch-*/bench-full/<workload>/<env>/<variant>/solo/repN/profiler.tsv
                                              │
                                              ▼ convert-profiler-to-meyer.py
                                     <repN>.meyer.csv  (7-col integer, ;-sep)
                                              │
                                              ▼ generate-iada-tree.py
                          iada-tree/<variant>/<env>/source/<workload>/{inc,dec,osc,con}.csv
                                              │
                                              ▼ generate-iada-input.py
                                      input.txt (app + pm declarations)
                                              │
                                              ▼ symlink resources/workload/interference
                                              ▼ run-iada-experiment.sh
                              CloudSim (Java) ↔ JRI ↔ R (SVM + K-means + CPD)
                                              │
                                              ▼ parse-cloudsim-output.py
                                  metrics.tsv (idi, migrations, etc.)
```

Ver `intp/bench/iada/scripts/` para todos os componentes.

---

## Configurações de ambiente que importam

Validadas em smoke test, **obrigatórias** para evitar segfault do JRI:

| Var/Flag | Valor | Por quê |
|---|---|---|
| `JAVA_HOME` | `/usr/lib/jvm/java-17-openjdk-amd64` | Java 25 funciona, mas LTS 17 é referência |
| `-DR_SignalHandlers=0` | obrigatório | R 4.3 instala signal handlers que conflitam com JVM → segfault em `library(caret)` |
| `LD_LIBRARY_PATH` | `<rJava/jri>:<R/lib>` | libjri.so + libR.so |
| `R_LIBS_USER` | `~/R/library` | Pacotes em userlib (não system) |
| `INTP_R_FOLDER` | path do `R/` no checkout | substitui hostname-hardcoded paths em MLClassifier.java |
| `-XX:+UseSerialGC -Xss8m` | recomendado | reduz threading com R nativo |

---

## Métricas extraídas (alinhadas com IADA paper Sec. V)

| Métrica | Cardinalidade | Origem |
|---|---|---|
| `cloudletcost_avg/sum` | escalar / 192 | tabela placement final |
| `interference_avg/sum/max` | escalar / N intervalos | `Algorithm: SAO` block |
| `migrations_total/avg` | escalar / N-1 | `Migrations:` block |
| **`idi_avg/sum/max`** | **escalar / N** | **`interf with mig:` block -- métrica principal do paper** |
| `sim_wallclock_min` | escalar | tempo de execução |
| `classifier_calls` | escalar | overhead de classificação |

**`idi`** = TotalInterferenceCost + (migrations × migvalue) -- é o índice de
degradação por interferência *com* o custo de migração embutido. Quanto menor,
melhor o scheduling.

---

## Smoke test confirmado (dataset original do paper IADA)

Usando dataset de `src/resources/workload/interference/192_48/`
(192 cloudlets sintéticos: cpu, memory, disk, network × stressors):

```
variant=ORIG env=paper workload_mix=192_48
  cloudlets=192  intervals=24  idi_avg=3476.2  migrations=84  wallclock=26min
```

Pipeline validado end-to-end. 26 minutos para 192 apps -- bom referencial
para estimar custo da campanha completa.

---

## Plano da campanha

### Fase 0 -- Scaffold + smoke (concluído 2026-05-05)
- [x] R + rJava + libtirpc-dev instalados
- [x] CloudSim compilado com Java 17, classes pré-existentes funcionam
- [x] Patch MLClassifier.java -- env vars `INTP_R_FOLDER`/`INTP_R_LIBPATHS`
- [x] Smoke test 192 cloudlets paper-original
- [x] Scripts: run-iada-experiment.sh, generate-iada-input.py, parse-cloudsim-output.py, run-iada-campaign.sh

### Fase 1 -- Validação cruzada (próximo)
Quando a Fase 2 da campanha IntP rodar HiBench em V3.1/V3 e gerar primeiro
conjunto Meyer real:
- [ ] Rodar `generate-iada-tree.py` no `bench-full/`
- [ ] Rodar 1 simulação de smoke: `run-iada-experiment.sh` com V3.1/bare
- [ ] Verificar que IDI e migrations são plausíveis vs paper-baseline

### Fase 2 -- Campanha completa
Após Fases 3-5 do plano IntP terminarem:
- [ ] Rodar `run-iada-campaign.sh` para todas as combinações V × env disponíveis
- [ ] Gerar manifest.tsv consolidado
- [ ] Plot comparativo IDI por variante (script ainda a escrever)

### Fase 3 -- Análise
- [ ] Rank de variantes por idi_avg
- [ ] Correlação fragility (do IntP) ↔ IDI degradation
- [ ] Plot env-impact: bare vs container vs vm para mesma variante

---

## Estimativa de custo

| Item | ETA |
|---|---|
| 1 simulação (192 apps, 48 PMs, 24 intervalos) | ~26 min |
| 6 variantes × 3 envs × 1 mix | 18 simulações = ~8h |
| 6 variantes × 3 envs × 5 mixes (futuro) | ~40h |

Tudo local. Não compete com Hetzner.

---

## Decisões metodológicas (registradas)

1. **Sem retreino de SVM/K-means.** Modelos pré-treinados em `forced/`
   (stressors sintéticos do paper) são mantidos fixos. Variar o input
   isola a hipótese sobre fidelidade da instrumentação. Retreino
   por-variante seria uma hipótese complementar (futuro).

2. **CloudSim local.** O simulador é determinístico; não há valor em
   rodar em hardware diferente. O servidor Hetzner permanece dedicado
   à instrumentação IntP.

3. **Variar env nos perfis, não no simulador.** Quando dizemos "rodar em
   diferentes envs", queremos perfis vindos de bare/container/vm
   (instrumentação de fato afetada pelo env), não o CloudSim em si.

4. **24 intervalos é resultado de CPD, não parametrização.** O Change
   Point Detection no R determina quantos intervalos cada simulação tem.
   Variantes diferentes podem produzir N diferente.

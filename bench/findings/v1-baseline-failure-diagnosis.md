# V1 Baseline — Diagnóstico de Falha de Compilação

**Data do diagnóstico:** 2026-04-30
**Host:** intp-v1-baseline
**Kernel:** 6.5.0-45-generic (`6.5.0-45.45~22.04.1` Ubuntu HWE)
**OS:** Ubuntu 22.04.5 LTS
**CPU:** Intel Xeon Gold 5412U (1 socket, 48 cores, 251 GB RAM)

---

## Contexto

A campanha de baseline V1 foi executada neste host com os dados arquivados em
`v1-full-campaign-all-envs/`. Ao analisar os resultados, verificou-se que
todas as execuções V1 produziram `samples=0` e todas as métricas no
`aggregate-means.tsv` ficaram marcadas como `--`.

A investigação dos logs de profiler (`profiler.stap.log`) revelou que a falha
ocorreu **antes de qualquer coleta de dados**, na fase de compilação do módulo
SystemTap (Pass 4).

---

## Resultado dos checks de diagnóstico

```
# Versão do SystemTap
stap --version 2>&1 | head -1
→ Systemtap translator/driver (version 5.2/0.186, release-5.2)   ✅

# Binário do SystemTap 5.2 compilado do fonte
ls -la /usr/local/bin/stap
→ -rwxr-xr-x 1 root root 71784736 Apr 30 13:27 /usr/local/bin/stap   ✅

# Presença de cqm_rmid nos headers do kernel em uso
grep -r cqm_rmid /usr/src/linux-headers-$(uname -r)/
→ cqm_rmid AUSENTE nos headers -- V1 NAO COMPILA   ❌

# MSR_IA32_QM nos headers (causam conflito de redefinição no probe)
grep "MSR_IA32_QM" /usr/src/linux-headers-$(uname -r)/arch/x86/include/asm/msr-index.h
→ #define MSR_IA32_QM_EVTSEL  0xc8d
  #define MSR_IA32_QM_CTR     0xc8e   ⚠️ já definidos pelo kernel

# Smoke test do SystemTap (probe mínimo)
echo 'probe begin { println("stap ok"); exit() }' | sudo stap -
→ stap ok   ✅
```

---

## Causa raiz

O campo `cqm_rmid` em `struct hw_perf_event`, usado pelo V1 para vincular
um RMID Intel RDT a um perf event do kernel, **foi removido ou refatorado**
no pacote `linux-headers-6.5.0-45.45~22.04.1` do Ubuntu HWE.

O V1 assume acesso direto a esse campo interno em duas passagens do probe:

```c
rr.rmid = pe->hw.cqm_rmid;         // linha 85 do C gerado pelo stap
if (pe->hw.cqm_rmid == rr.rmid)    // linha 95
```

Sem `cqm_rmid`, o compilador C rejeita o módulo. Somado a isso, os MSRs
`MSR_IA32_QM_CTR` e `MSR_IA32_QM_EVTSEL` já estão definidos no header
`arch/x86/include/asm/msr-index.h`, causando **erro de redefinição** adicional
quando o SystemTap tenta redeclará-los no código gerado.

O resultado são quatro erros fatais em Pass 4, presentes de forma idêntica
em **todos** os logs de todas as execuções V1 (bare, container, vm):

```
error: "MSR_IA32_QM_CTR" redefined [-Werror]
error: "MSR_IA32_QM_EVTSEL" redefined [-Werror]
error: 'struct hw_perf_event' has no member named 'cqm_rmid'   (x2)
Pass 4: compilation failed.  [man error::pass4]
```

---

## O que não foi a causa

| Hipótese | Descartada por |
|---|---|
| Falta de debug symbols | Nenhuma mensagem de debuginfo/DWARF nos logs; dbgsym 6.5.0-45 instalado |
| SystemTap desatualizado (4.6) | stap 5.2 compilado do fonte, em `/usr/local/bin/stap` |
| Hardware incompatível | `capabilities.env` confirma RDT/CQM disponível; `stap ok` funciona |
| Falha transiente / noise | Erro idêntico, determinístico, em todas as repetições e ambientes |

---

## Conclusão para o paper

O V1 **não pode compilar** nesse kernel sem modificações no probe, independente
de quantas vezes seja reexecutado. O campo `cqm_rmid` foi removido como parte
da refatoração da interface interna de perf/RDT que a Canonical incorporou no
pacote HWE `6.5.0-45.45~22.04.1`, mesmo que o número de versão 6.5 ainda
esteja dentro do range documentado como "suportado".

Isso motiva diretamente:
- **V2**: patch mínimo que elimina a dependência de `cqm_rmid` e o conflito de MSR,
  ao custo de remover `llcocc`.
- **V3**: restauração das 7 métricas via `/sys/fs/resctrl`, sem dependência de
  campo interno de `hw_perf_event`.
- **V4/V5/V6**: abordagens sem SystemTap, imunes a esse tipo de drift de ABI.

A campanha arquivada em `v1-full-campaign-all-envs/` deve ser citada no paper
como **evidência de quebra de portabilidade do V1**, não como dados de desempenho.

---

## Referências internas

- Logs de falha: `v1-full-campaign-all-envs/**/profiler.stap.log` (linha 19+)
- Índice de amostras: `v1-full-campaign-all-envs/index.tsv` (todas as linhas V1 com `samples=0`)
- Agregados: `v1-full-campaign-all-envs/aggregate-means.tsv` (todas as colunas V1 com `--`)
- Documentação do problema: `docs/KERNEL-6.8-CHANGES.md`
- Patch que resolve: `v2-updated/intp-6.8.stp`
- Bootstrap do baseline: `bench/setup/setup-host.sh` função `install_legacy_stack()`

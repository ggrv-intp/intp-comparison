# LAD pantanal01 -- RDT monitoring inviável em Skylake-SP gen1

**Date observed:** 2026-05-04
**Host:** pantanal01.lad.pucrs.br
**CPU:** Intel Xeon Gold 5118 (Skylake-SP gen1), stepping 4
**Microcode:** 0x2007006
**Kernel:** 5.15.0-163-generic (Ubuntu 22.04.5 LTS)

---

## Resumo

A combinação CPU + microcódigo + kernel disponível no LAD pantanal01 **não expõe**
as features de Cache Monitoring Technology (CMT) e Memory Bandwidth Monitoring
(MBM) via interface `resctrl`, apesar das flags de CPUID declararem suporte.
Isso impossibilita a coleta da métrica `llcocc` em qualquer variante do IntP
(V1, V3, V4, V5, V6) neste hardware.

Implicação: cobertura máxima da metodologia IntP no LAD pantanal01 é 6/7
métricas, independente da variante de instrumentação escolhida.

---

## Evidência empírica

### O que CPUID promete

Flags presentes em `/proc/cpuinfo`:

```
cqm   cqm_llc   cqm_occup_llc   cqm_mbm_total   cqm_mbm_local
cat_l3   mba   rdt_a
```

Sugerem suporte completo a Intel RDT: monitoring (CMT, MBM) e allocation
(CAT, MBA).

### O que o kernel resctrl driver realmente entrega

Verificação após mount do resctrl:

```bash
$ sudo mount -t resctrl resctrl /sys/fs/resctrl
mount: /sys/fs/resctrl: resctrl already mounted on /sys/fs/resctrl.

$ ls /sys/fs/resctrl/info/L3_MON/
ls: cannot access '/sys/fs/resctrl/info/L3_MON/': No such file or directory

$ sudo mkdir /sys/fs/resctrl/mon_groups/test
$ sudo cat /sys/fs/resctrl/mon_groups/test/mon_data/mon_L3_*/llc_occupancy
cat: '...llc_occupancy': No such file or directory
```

Mensagens do kernel durante init do resctrl:

```bash
$ sudo dmesg | grep -i resctrl
[    4.402824] resctrl: MB allocation detected
```

**Apenas MBA (Memory Bandwidth Allocation) foi detectada.** Nem L3 cache
monitoring (CMT), nem memory bandwidth monitoring (MBM), nem L3 allocation
(CAT) foram inicializadas pelo driver, mesmo com as flags de CPUID
declarando suporte.

### Diagnóstico

O kernel resctrl driver detectou as flags via CPUID mas decidiu **não ativar**
as features de monitoring. Causas plausíveis (não-mutuamente exclusivas):

1. **Errata Intel documentada para Skylake-SP gen1.** A primeira geração de
   Xeon Scalable teve múltiplos errata em RDT/CMT (referência: Intel Xeon
   Processor Scalable Family Specification Update). Stepping 4 do Gold 5118
   está na faixa afetada.
2. **Microcode 0x2007006** está em série posterior às mitigações
   Spectre/MDS, que degradaram funcionalidade RDT em diversas SKUs
   Skylake-SP. Em vários casos, microcode subsequente desabilita CMT/MBM
   silenciosamente para evitar canais laterais.
3. **Kernel quirk list.** O resctrl driver no kernel Linux mantém lista de
   CPUs com RDT problemática e suprime init de monitoring quando detecta
   combinação known-bad — comportamento conservador e correto.

Independentemente da causa exata, o resultado observável é determinístico
e independe de root, kernel parameters ou software de instrumentação:
**`llcocc` não pode ser lida via resctrl neste host.**

---

## Implicação para a metodologia IntP

A métrica `llcocc` (LLC occupancy) é uma das sete métricas centrais
definidas no paper IntP de Xavier et al. (SBAC-PAD 2022, Sec. III-E).
No paper original, ela é coletada via leitura direta de `task_struct->cqm_rmid`
no kernel (campo removido em kernel 6.8+).

Caminhos alternativos para coletar `llcocc` em hardware moderno:

- **V1 (kernel <=6.6):** lê `cqm_rmid` direto. Requer que o monitoring esteja
  habilitado pelo kernel — se o resctrl driver não ativa CMT, o RMID
  não é alocado e o campo retorna lixo ou zero.
- **V3 / V4 / V5 / V6:** leem via interface `resctrl` em `/sys/fs/resctrl/`.
  Requer que `info/L3_MON/` exista e que mon_groups consigam ser criados
  com `mon_data/mon_L3_*/llc_occupancy` populado.

Em pantanal01, **nenhum** desses caminhos funciona. Isso é uma limitação
de hardware/microcode/kernel, não de software de instrumentação.

---

## Decisão metodológica decorrente

A migração da infraestrutura experimental de LAD/PUCRS para Hetzner
(servidor dedicado com Xeon Gold 5412U / Sapphire Rapids gen4) **não foi
opcional** — foi imposta pelo requisito de cobertura completa das 7 métricas
do paper IntP. Sapphire Rapids é a primeira geração Intel onde:

- RDT monitoring (CMT, MBM) é detectado e exposto via resctrl sem ressalvas.
- CAT e MBA funcionam em conjunto com monitoring.
- Não há erratas que forcem o kernel a degradar features.

Verificação no Hetzner:

```bash
# Mesmo procedimento, host intp-master (Xeon Gold 5412U):
$ sudo mount -t resctrl resctrl /sys/fs/resctrl
$ ls /sys/fs/resctrl/info/L3_MON/
mon_features  num_rmids  ...
$ sudo dmesg | grep -i resctrl
[ ... ] resctrl: L3 allocation detected
[ ... ] resctrl: MB allocation detected
[ ... ] resctrl: L3 monitoring detected
[ ... ] resctrl: Memory bandwidth monitoring detected
```

Cobertura: 7/7 métricas em qualquer variante.

---

## O que ainda pode ser rodado em pantanal01

Apesar da limitação de `llcocc`, o LAD pantanal01 segue útil para:

1. **Reprodução parcial de V1** com cobertura 6/7 (excluindo `llcocc`).
   Demonstra que a metodologia legada continua executável em hardware
   da era original do paper.
2. **Sanity check de portabilidade de V4** (procfs+perf+resctrl, único
   variante que roda sem dependência de framework de kernel).
   Comparação cross-host (LAD vs Hetzner) das 6 métricas comuns valida
   transferibilidade dos resultados.

---

## Comandos de verificação (reproduzíveis)

Qualquer pessoa pode auditar este achado executando:

```bash
# 1) Hardware advertising
grep -oE 'cqm[a-z_]*|cat_l3|mba|rdt_a' /proc/cpuinfo | sort -u

# 2) Kernel CONFIG
grep -E 'CONFIG_X86_CPU_RESCTRL|CONFIG_PROC_CPU_RESCTRL' \
     /boot/config-$(uname -r)

# 3) resctrl driver init (decisão real do kernel)
sudo dmesg | grep -i resctrl

# 4) Tentativa empírica
sudo mount -t resctrl resctrl /sys/fs/resctrl 2>&1
ls /sys/fs/resctrl/info/
ls /sys/fs/resctrl/info/L3_MON/ 2>&1
```

Se `dmesg` reporta apenas "MB allocation detected" e `info/L3_MON/` não
existe, a limitação está confirmada.

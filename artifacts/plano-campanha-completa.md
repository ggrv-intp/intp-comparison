# Plano de campanha completa -- IntP multi-variante

**Status:** rascunho 2026-05-05
**Pré-requisito:** campanha v4-v6+v3 atual (`big-batch-pervariant-20260504_210032`)
deve terminar primeiro (~14h de 05/05).

---

## Visão geral das 5 fases

| Fase | Conteúdo | Hospedeiro | Variantes | Envs | Workloads | ETA |
|---|---|---|---|---|---|---|
| 0 | Setup HiBench local-mode | Hetzner | -- | -- | -- | ~30 min |
| 1 | Atual em curso | Hetzner | v3-v6 | bare | sintéticos | ~14h (em andamento) |
| 2 | Re-run com HiBench funcional | Hetzner | v3-v6 | bare | sint + real | ~15-20h |
| 3 | V2 completo | Hetzner | v2 | bare | sint + real | ~6-10h |
| 4 | Container + VM para V2-V6 | Hetzner | v2-v6 | container, vm | sint + real | ~30-40h |
| 5 | V1 em Ubuntu 22 | Hetzner (dual-boot) | v1 | bare, container, vm | sint + real | ~15h |

**Total estimado: 80-100 horas de campanha** (~4-5 dias rodando contínuo).

---

## Fase 0 -- Setup HiBench em local-mode (pode rodar AGORA)

**Por que agora:** o script só baixa Hadoop binary (~600MB) e configura HiBench.
Nenhuma carga pesada. Pode rodar enquanto a campanha v4-v6 atual segue.

### Deploy do script

```bash
# Local: enviar o script de setup
scp -i ~/.ssh/id_ed25519 \
    /home/dedealien/Documents/intp/bench/hibench/setup-hadoop-localmode.sh \
    root@195.201.193.143:/root/intp/bench/hibench/setup-hadoop-localmode.sh
```

### Executar só a parte de instalação (sem dataset prep, pra não competir com campanha)

```bash
ssh -i ~/.ssh/id_ed25519 root@195.201.193.143
# dentro do servidor:
cd /root/intp
SKIP_DATA_PREP=1 SKIP_SMOKE=1 sudo bash bench/hibench/setup-hadoop-localmode.sh
```

Isso baixa Hadoop, configura, e patcha HiBench. **Não roda nada pesado.**
Demora ~5 min no total.

### Verificar instalação (rápido, baixo impacto)

```bash
ls -la /opt/hadoop /opt/HiBench/conf/
grep -E 'hadoop.home|hdfs.master|workload.input' /opt/HiBench/conf/*.conf
```

---

## Fase 1 -- Aguardar campanha atual

**Status atual (05/05 02:30):** v5/solo em curso (~37/60).
**ETA:** v3 termina ~14:00-16:00 hoje.

Durante esse tempo, **não fazer mais nada pesado** no servidor. Só monitorar.

Quando terminar, baixar resultados:

```bash
# Local
mkdir -p ~/Documents/intp/results/
rsync -avz -e 'ssh -i ~/.ssh/id_ed25519' \
   root@195.201.193.143:/root/intp/results/big-batch-pervariant-20260504_210032/ \
   ~/Documents/intp/results/big-batch-pervariant-20260504_210032/
```

---

## Fase 2 -- Preparar HiBench datasets + smoke test (após Fase 1)

```bash
ssh -i ~/.ssh/id_ed25519 root@195.201.193.143
cd /root/intp

# Dataset prep (só de fato roda agora) + smoke test que valida HiBench end-to-end
sudo bash bench/hibench/setup-hadoop-localmode.sh
```

Isso vai:
1. Pular install (já feito)
2. Pular config (já feito)
3. **Preparar datasets** (10-30 min, gera dados em `/var/lib/hibench/input/`)
4. **Smoke test wordcount** (~5 min, valida que HiBench-Spark roda end-to-end com profiler)

Verifique no fim que smoke test reportou OK. Se sim, HiBench está pronto.

---

## Fase 3 -- Re-run completo V3-V6 com HiBench funcional

```bash
ssh -i ~/.ssh/id_ed25519 root@195.201.193.143
tmux new -s intp-real
cd /root/intp

TS=$(date +%Y%m%d_%H%M%S)
OUT=/root/intp/results/big-batch-real-$TS
mkdir -p "$OUT"
ln -sfn "$OUT" /root/intp/results/LATEST-BIG

for VARIANT in v4 v5 v6 v3; do
  echo "=== Variante: $VARIANT ($(date -Iseconds)) ==="
  if [ "$VARIANT" = "v3" ]; then
    pkill -KILL -f stapio 2>/dev/null; sleep 1
    lsmod | awk '/^stap_/{print $1}' | xargs -r -n1 rmmod -f 2>/dev/null
    bash /root/intp/shared/intp-resctrl-helper.sh stop 2>/dev/null
  fi
  sudo \
    BENCH_VARIANTS=$VARIANT \
    BENCH_ENVS=bare \
    DURATION=120 REPS=4 INTERVAL=1 \
    WARMUP=15 COOLDOWN=10 \
    TIMESERIES_DURATION=600 OVERHEAD_DURATION=60 \
    RUN_HIBENCH=1 HIBENCH_SIZE=medium HIBENCH_PROFILE=both HADOOP_PROFILE=3 \
    RUN_PLOTS=0 \
    INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
    RESUME_DIR=$OUT \
    bash run-big-batch.sh \
    || echo "WARN: variant $VARIANT failed/partial"
done

# Pós-processamento
sudo python3 /root/intp/bench/plot/extract-fragility.py "$OUT/bench-full"
sudo python3 /root/intp/bench/plot/plot-intp-bench.py "$OUT/bench-full" || true
sudo python3 /root/intp/bench/convert-profiler-to-meyer.py "$OUT/bench-full" \
     --stage solo --output-root "$OUT/bench-full/meyer" \
     --manifest "$OUT/bench-full/meyer/manifest.tsv"
sudo python3 /root/intp/bench/generate-iada-tree.py \
     --manifest "$OUT/bench-full/meyer/manifest.tsv" \
     --out-root "$OUT/bench-full/iada-tree" \
     --variant v4 --variant v5 --variant v6 --stage solo
```

ETA: ~15-20h.

---

## Fase 4 -- V2 completo bare (após Fase 3)

```bash
tmux new -s intp-v2
cd /root/intp
sudo \
  BENCH_VARIANTS=v2 \
  BENCH_ENVS=bare \
  DURATION=120 REPS=4 INTERVAL=1 \
  WARMUP=15 COOLDOWN=10 \
  TIMESERIES_DURATION=600 OVERHEAD_DURATION=60 \
  RUN_HIBENCH=1 HIBENCH_SIZE=medium HIBENCH_PROFILE=both HADOOP_PROFILE=3 \
  RUN_PLOTS=0 \
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
  RESUME_DIR=$OUT \
  bash run-big-batch.sh
```

ETA: ~6-10h. RESUME_DIR aponta para o mesmo $OUT da Fase 3, então tudo
consolida no mesmo diretório.

---

## Fase 5 -- V2-V6 em container + VM

### Pré-requisito: criar imagem qcow2 Ubuntu 24.04 (uma vez só)

```bash
# No Hetzner:
cd /var/lib/intp
mkdir -p /var/lib/intp/vm-images && cd /var/lib/intp/vm-images

# Baixar cloud image oficial
wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img \
     -O ubuntu24.qcow2.tmp

# Redimensionar para 50G
qemu-img resize ubuntu24.qcow2.tmp 50G
mv ubuntu24.qcow2.tmp /var/lib/intp/ubuntu24.qcow2

# Cloud-init seed (configura senha + SSH key na primeira boot)
cat > user-data <<EOF
#cloud-config
users:
  - name: root
    plain_text_passwd: intp
    lock_passwd: false
runcmd:
  - apt update -qq
  - apt install -y stress-ng python3 python3-pip openjdk-17-jdk-headless
  - mount -t resctrl resctrl /sys/fs/resctrl 2>/dev/null
EOF
echo "instance-id: intp-vm-01" > meta-data
cloud-localds /var/lib/intp/seed.iso user-data meta-data

# Test boot
qemu-system-x86_64 -enable-kvm -m 16G -smp 8 \
    -drive file=/var/lib/intp/ubuntu24.qcow2,format=qcow2 \
    -drive file=/var/lib/intp/seed.iso,format=raw \
    -nic user,hostfwd=tcp::2222-:22 -nographic &
# (esperar boot, testar SSH, então kill)
```

Custo de tempo: ~30 min para preparar imagem.

### Campanha container

```bash
tmux new -s intp-container
cd /root/intp
sudo \
  BENCH_VARIANTS=v2,v3,v4,v5,v6 \
  BENCH_ENVS=container \
  CONTAINER_IMAGE=ubuntu:24.04 \
  DURATION=120 REPS=4 INTERVAL=1 \
  WARMUP=15 COOLDOWN=10 \
  TIMESERIES_DURATION=600 OVERHEAD_DURATION=60 \
  RUN_HIBENCH=1 HIBENCH_SIZE=medium HIBENCH_PROFILE=both \
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
  RESUME_DIR=$OUT \
  bash run-big-batch.sh
```

ETA: ~15-20h.

### Campanha VM

```bash
tmux new -s intp-vm
cd /root/intp
sudo \
  BENCH_VARIANTS=v2,v3,v4,v5,v6 \
  BENCH_ENVS=vm \
  VM_IMAGE=/var/lib/intp/ubuntu24.qcow2 \
  VM_MEM=32G VM_CPUS=16 \
  DURATION=120 REPS=4 INTERVAL=1 \
  WARMUP=15 COOLDOWN=10 \
  TIMESERIES_DURATION=600 OVERHEAD_DURATION=60 \
  RUN_HIBENCH=1 HIBENCH_SIZE=medium HIBENCH_PROFILE=both \
  INTP_BENCH_V3_DEEP_CLEANUP_EVERY=5 \
  RESUME_DIR=$OUT \
  bash run-big-batch.sh
```

ETA: ~20-25h. VM tem overhead do hipervisor, mais lento.

---

## Fase 6 -- V1 em Ubuntu 22 (kernel 5.15) -- outro disco

### Pré-requisitos

1. Disco com Ubuntu 22 já instalado e com SSH ativo
2. Bootloader (GRUB) configurável para boot no segundo disco
3. SystemTap 4.x + debuginfo do kernel 5.15 instalado
4. Hetzner Robot suporta seleção de boot device via painel

### Sequência

```bash
# 1) Reboot para Ubuntu 22 (via Hetzner Robot ou GRUB editor)
# 2) Aguardar boot (~3min), reconectar SSH
# 3) Validar ambiente:
ssh -i ~/.ssh/id_ed25519 root@195.201.193.143
uname -a   # confirmar 5.15.x
ls /var/cache/apt/archives/linux-image-*-dbgsym* 2>/dev/null   # confirmar debuginfo
mount -t resctrl resctrl /sys/fs/resctrl
git clone <repo> /root/intp
cd /root/intp
git checkout v1-systemtap   # branch v1 puro

# 4) Smoke V1 bare
sudo BENCH_VARIANTS=v1 BENCH_ENVS=bare \
     DURATION=60 REPS=2 RUN_HIBENCH=0 RUN_PLOTS=0 \
     bash run-big-batch.sh

# 5) Se smoke OK, campanha completa V1 em todos envs
TS=$(date +%Y%m%d_%H%M%S)
OUT=/root/intp/results/v1-ubuntu22-$TS
mkdir -p "$OUT"
for ENV in bare container vm; do
  echo "=== V1 / $ENV ==="
  sudo \
    BENCH_VARIANTS=v1 \
    BENCH_ENVS=$ENV \
    VM_IMAGE=/var/lib/intp/ubuntu22.qcow2 \
    DURATION=120 REPS=4 INTERVAL=1 \
    WARMUP=15 COOLDOWN=10 \
    TIMESERIES_DURATION=600 OVERHEAD_DURATION=60 \
    RUN_HIBENCH=1 HIBENCH_SIZE=medium HIBENCH_PROFILE=both \
    RUN_PLOTS=0 \
    RESUME_DIR=$OUT \
    bash run-big-batch.sh \
    || echo "WARN: V1 $ENV failed"
done
```

ETA: ~10-15h.

### Voltar para Ubuntu 24 depois

```bash
# Via Hetzner Robot ou GRUB
reboot
# (selecionar entrada do disco Ubuntu 24 no GRUB ou no painel da Hetzner)
```

---

## Tabela de comandos resumida

| Fase | Comando inicial | Output dir |
|---|---|---|
| 0 | `SKIP_DATA_PREP=1 SKIP_SMOKE=1 bash bench/hibench/setup-hadoop-localmode.sh` | -- |
| 1 | (em curso) | `big-batch-pervariant-20260504_210032` |
| 2 | `bash bench/hibench/setup-hadoop-localmode.sh` | -- (popula `/var/lib/hibench/`) |
| 3 | for variant; resume com $OUT comum | `big-batch-real-<ts>` |
| 4 | mesmo $OUT, BENCH_VARIANTS=v2 | mesmo |
| 5a | mesmo $OUT, BENCH_ENVS=container | mesmo |
| 5b | novo OUT, BENCH_ENVS=vm | `big-batch-vm-<ts>` |
| 6 | reboot Ubuntu 22, novo OUT | `v1-ubuntu22-<ts>` |

---

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| HiBench prepare falha (smoke test não passa) | Não avançar Fase 3 antes de OK; debug isolado |
| V3 deadlock em HiBench (Spark JVM = mais probes) | Patch comm-resolution já aplicado; cleanup pre-run + 8s pause cada 5 runs |
| VM dataset prep dentro da VM falha | Usar mesmo qcow2 com dataset pré-baked; `cloud-init` para deps |
| Reboot para Ubuntu 22 falha | Painel Hetzner Robot tem KVM remoto pra debug |
| Cobrança Hetzner extra por dias adicionais | ~$0,24/h × ~80h adicionais = ~$20 (R$110) |
| SSH cair durante reboot Ubuntu 22 | Hetzner Robot: ip continua o mesmo, só esperar boot |

---

## Salvaguardas em cada fase

Após cada fase, **salvar resultados localmente** para não perder em caso de
crash do servidor:

```bash
rsync -avz -e 'ssh -i ~/.ssh/id_ed25519' \
   root@195.201.193.143:/root/intp/results/<dir-da-fase>/ \
   ~/Documents/intp/results/<dir-da-fase>/
```

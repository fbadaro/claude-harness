# claude-harness

Proteções reaproveitáveis para projetos desenvolvidos com o [Claude Code](https://claude.com/claude-code). São três hooks em bash + jq:

| Hook | Quando roda | O que faz |
|---|---|---|
| `guard.sh` | Antes de cada comando de terminal do agente (PreToolUse: `Bash`, `PowerShell`, `Monitor`) | Bloqueia comandos destrutivos de `git` e `gh`: push para a branch protegida, force-push, `reset --hard`, merge com CI vermelho e outros |
| `format.sh` | Depois de cada edição de arquivo do agente (PostToolUse: `Edit`, `Write`, `MultiEdit`) | Formata o arquivo editado com o formatador configurado para a extensão dele |
| `pre-push` | Em todo `git push`, inclusive os digitados por você | Rejeita push para a branch protegida e qualquer push que não seja fast-forward |

Funciona em qualquer repositório git, em qualquer linguagem, no Windows (Git Bash), Linux e macOS.

## Modelo de ameaça

O harness é uma **barreira de boa-fé contra acidentes** de um agente cooperativo, não um sandbox:

* O `pre-push` é a **proteção principal**. O git entrega a ele as refs reais do push, já resolvidas (aliases, variáveis, `HEAD`), então não há como enganá-lo pelo texto do comando. Só um `git push --no-verify` o contorna, e a guarda bloqueia essa opção.
* A `guard.sh` **não interpreta shell**. Ela tira as aspas, separa o comando nos separadores (`;`, `&&`, `|`, quebras de linha...) e examina os argumentos de cada chamada a `git`/`gh`, inclusive dentro de `bash -c "..."` ou `pwsh -Command "..."`. Um agente determinado a contorná-la consegue (por exemplo, gerando um script e executando). Para isso existe o `pre-push`, e a proteção de branch do GitHub, se o seu plano tiver.
* Quando não consegue decidir, a guarda **bloqueia** (fail-closed). Isso vale para JSON inválido, `jq` ausente e branch atual desconhecida.
* O `harness.conf` é **lido, nunca executado**. Só as chaves conhecidas são aceitas, e um valor inválido mantém a regra ligada: um `PROTECTED_BRANCH` inválido faz o `pre-push` rejeitar o push. Assim, um agente que edite o arquivo não consegue rodar código nem desligar o `pre-push`.
* O `settings.example.json` **nega ao agente** editar `.claude/harness/`, `.claude/harness.conf` e `.claude/settings.json` pelas ferramentas de edição. Quem muda a configuração é você.

## Pré-requisitos

| | Windows | macOS | Linux |
|---|---|---|---|
| bash ≥ 4.4 | Git Bash, que já vem com o Git for Windows e é exigido pelo Claude Code | `brew install bash` (o bash do sistema é 3.2) | já instalado |
| jq ≥ 1.7 | `winget install jqlang.jq` | `brew install jq` | `sudo apt install jq` |
| git | Git for Windows | já instalado | já instalado |
| gh (opcional) | `winget install GitHub.cli` | `brew install gh` | [cli.github.com](https://cli.github.com) |

O `gh` só é necessário para a regra "merge só com checks verdes" (`REQUIRE_GREEN_CHECKS=1`).

> **Depois de instalar o `jq`, reinicie o Claude Code.** Os hooks herdam o PATH da sessão. Sem o `jq`, a guarda bloqueia **todos** os comandos de terminal e mostra a instrução de instalação.

## Instalação

1. **Copie o harness para o projeto**, numa tag fixa:

   ```sh
   git clone --depth 1 --branch v0.1.1 https://github.com/fbadaro/claude-harness /tmp/claude-harness
   sh /tmp/claude-harness/install.sh /caminho/do/projeto
   ```

   O `install.sh`:
   * copia os scripts para `.claude/harness/` e grava a versão em `.claude/harness/VERSION`;
   * cria `.claude/harness.conf` a partir do exemplo, **só se ele ainda não existir**;
   * ativa o `pre-push` (`git config core.hooksPath .claude/harness`) se o `core.hooksPath` ainda não estiver definido. Se já estiver, ele avisa e não muda nada.

2. **Ligue os hooks no Claude Code.** Junte os blocos `permissions.deny` e `hooks` de [`settings.example.json`](settings.example.json) ao `.claude/settings.json` do projeto (crie o arquivo se não existir). As regras `deny` impedem o agente de editar a própria configuração das proteções. Depois disso, mudanças nesses arquivos são feitas por você, num editor. O `$CLAUDE_PROJECT_DIR` faz os hooks funcionarem mesmo quando o agente está numa subpasta.

3. **Configure e versione.** Ajuste os formatadores em `.claude/harness.conf`. Depois faça commit de `.claude/harness/`, `.claude/harness.conf` e `.claude/settings.json`. No Windows, preserve o bit de execução para quem clonar no Linux/macOS:

   ```sh
   git add --chmod=+x .claude/harness/pre-push .claude/harness/guard.sh .claude/harness/format.sh
   ```

Cada outro clone do projeto precisa rodar **uma vez** `git config core.hooksPath .claude/harness`. A configuração do git não é versionada. Por fim, reinicie o Claude Code (ou abra `/hooks`) para carregar os hooks.

## O que a guarda bloqueia

`<protegida>` é o `PROTECTED_BRANCH` do `harness.conf` (padrão: `main`).

| Regra | Bloqueado (exemplo) | Liberado (exemplo) |
|---|---|---|
| Push para a branch protegida, inclusive criar ou apagar | `git push origin main`, `git push origin HEAD:main`, `git push origin :main` | `git push origin issue-12-x` |
| Push sem refspec estando na protegida, ou com branch desconhecida | `git push` (em `main`) | `git push` (em `issue-12-x`) |
| Push sem refspec depois de `cd`/`git -C` (o diretório real é incerto) | `cd ../outro && git push` | `cd ../outro && git push origin issue-12-x` |
| Force-push | `git push -f`, `--force-with-lease`, `git push origin +x` | `git push -u origin x` |
| Push de tudo | `--all`, `--mirror`, `--prune`, `git push origin :` | `git push origin v1.0.0` (tag) |
| Pular o `pre-push` | `git push --no-verify` | |
| Expansão de shell não resolvida em `push`/`reset`/`branch`/`config` | `git push origin $B` | `git status $X` |
| `reset --hard` | `git reset --hard HEAD~1` | `git reset --soft HEAD~1` |
| Apagar a branch protegida | `git branch -D main` | `git branch -D issue-3-old` |
| Desligar o `pre-push` | qualquer menção a `core.hooksPath`; `GIT_CONFIG*=`, `GIT_DIR=`, `GIT_EXEC_PATH=`, `HOME=`/`XDG_CONFIG_HOME=` junto de git; `--config-env`; `-c alias.*`/`-c include.*`; `git config alias.*`/`include.*` | `git -c color.ui=always log`, `GIT_TRACE=1 git status` |
| Comando que não dá para inspecionar | `pwsh -EncodedCommand ...` | |
| Merge com CI não verde (`REQUIRE_GREEN_CHECKS=1`) | `gh pr merge 12` com algum check `fail`/`pending`/`cancel`, ou sem checks | `gh pr merge 12 --squash` com todos `pass`/`skipping` |
| Merge depois de `cd` sem `--repo` | `cd ../outro && gh pr merge 3` | `cd ../outro && gh pr merge 3 --repo dono/repo` |
| Merge pela API | `gh api -X PUT repos/o/r/pulls/1/merge` | `gh api repos/o/r/pulls/1` |

Os casos completos estão em [`test/run.sh`](test/run.sh).

### Falsos positivos conhecidos

Como a guarda olha o texto, e não o significado, alguns comandos inofensivos são bloqueados:

* **Texto que menciona um comando bloqueado**, como `echo "git push origin main"` ou `git commit -m "evitar git reset --hard"`. Saída: reescreva o texto ou use `git commit -F arquivo.txt`.
* **Leitura de `core.hooksPath`**, como `git config --get core.hooksPath`. Saída: rode você mesmo no terminal (no Claude Code, com o prefixo `!`).

Se um bloqueio atrapalhar algo legítimo, **rode o comando você mesmo** (`! <comando>` no prompt do Claude Code) em vez de pedir ao agente que contorne a guarda.

## Configuração (`.claude/harness.conf`)

Uma linha `CHAVE=valor` por opção, lida pelos três hooks. O valor pode vir entre aspas, e é permitido um comentário `#` no fim da linha. O arquivo é **lido, não executado**: chaves desconhecidas e comandos são ignorados, e finais de linha CRLF funcionam. O `install.sh` nunca o sobrescreve.

| Chave | Padrão | Significado |
|---|---|---|
| `PROTECTED_BRANCH` | `main` | Branch protegida pela guarda e pelo `pre-push` |
| `REQUIRE_GREEN_CHECKS` | `1` | `1` = `gh pr merge` só com todos os checks `pass`/`skipping`; `0` = sem essa regra |
| `FORMAT_<ext>` | (nenhum) | Comando do formatador para a extensão `<ext>`. `{}` vira `./<caminho relativo ao projeto>` |
| `FORMAT_DIR_<ext>` | (nenhum) | Roda o formatador dentro dessa subpasta, com o caminho relativo a ela; arquivos fora dela são ignorados |
| `FORMAT_SKIP` | (vazio) | Prefixos de caminho (separados por espaço) nunca formatados, como código gerado |

Exemplo de um projeto Go + Python:

```sh
PROTECTED_BRANCH=main
REQUIRE_GREEN_CHECKS=1
FORMAT_go="gofmt -w {}"
FORMAT_py="uv run ruff format {}"
FORMAT_DIR_py=ml                  # o pyproject.toml está em ml/
FORMAT_SKIP="internal/gen/ ml/src/generated/"
```

O comando do formatador é separado por espaços, **sem aspas e sem expansão de shell**. Assim, um arquivo chamado `-v.go` nunca vira uma opção, porque recebe o prefixo `./`. Se o formatador não for encontrado ou falhar, o `format.sh` mostra um aviso, mas nunca bloqueia a edição.

## Recuperação: "todo comando está bloqueado"

Com `onFailure: "block"`, um erro na guarda (por exemplo, falta de `jq` ou um script corrompido) bloqueia todos os comandos de terminal. Para sair disso:

1. Leia a mensagem: ela diz o motivo, como "jq not found" com o comando de instalação.
2. Corrija o arquivo pela ferramenta de edição do Claude Code, que não passa pela guarda, ou instale o que falta e reinicie o Claude Code.
3. Em último caso, desative o hook em `/hooks` e reative depois de corrigir.

## Atualização

Rode o `install.sh` de uma tag nova. Ele substitui `.claude/harness/` inteiro e mantém o seu `harness.conf`. **Não edite os scripts copiados**: mudanças vão para este repositório e voltam pela próxima tag. A versão instalada fica em `.claude/harness/VERSION`.

## Desenvolvimento

```sh
bash test/run.sh          # tabela de casos: guard, format, pre-push e install
shellcheck harness/*.sh harness/pre-push install.sh test/run.sh
```

Toda regra nova entra com pelo menos um caso bloqueado e um liberado em `test/run.sh`. O CI roda os dois comandos no Ubuntu e no Windows.

A guarda roda em todo comando do agente, então evita criar processos: um comando liberado custa só o bash e uma chamada ao `jq`, cerca de 110 ms no Windows.

## Licença

[MIT](LICENSE)

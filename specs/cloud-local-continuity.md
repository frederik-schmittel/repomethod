# Task: Bruchfreier Cloud-/Lokal-Agent-Workflow

## Context

Die Gate- und Workflow-Korrekturen bis einschließlich `51ae925` und `0a3cb0a`
sind vorhanden. Diese Spec schließt nur die fünf im Planning Brief benannten
Lücken. Das Review-Verdikt des Briefs bleibt verbindlich: Ein Worker darf ein
Paket vereinfachen, aber weder Scope noch Verhalten erweitern.

Ein frischer Worker erhält ausschließlich diese Spec, den aktuellen
Repository-Stand und die in seinem Paket genannten Dateien. Er braucht keine
Entscheidung aus dem ursprünglichen Chat.

Die verlangten Skills `superpowers:brainstorming`,
`superpowers:writing-plans`, `superpowers:test-driven-development` und
`ponytail` sind in der aktuellen Codex-Skill-Liste nicht installiert. Die
Planung bildet ihre Prüfschritte deshalb explizit ab: festgelegte
Edge-Cases, RED vor GREEN, ein Minimalitätscheck pro Paket und feste
Stop-Bedingungen. Ein späterer Worker nutzt die Skills beziehungsweise
`/ponytail full`, sobald seine Laufzeit sie anbietet.

## Objective

Ein kalter Agent kann Quick MVP, Classic oder Graph lokal oder in der Cloud
aus committed Repository-Zustand fortsetzen und mit genau einem
Close-out-Kommando abschließen, ohne einen vorhandenen Workflow-Base neu zu
schätzen oder Evidence-Verhalten vom Host-`.gitignore` abhängig zu machen.

## Definition of Ready

- Die fünf Pakete haben feste CLI-Verträge, Fehlerfälle, Testnamen und
  Dateigrenzen.
- `verify-command` bleibt das einzige Pass/Fail-Signal für den eigentlichen
  Gate-Inhalt. Preflight, Warnungen und Ausgabeformat ändern dieses Signal
  nicht.
- `workflow-graph.sh init` ist die einzige Autorität, die für einen neuen
  zustandsbehafteten Workflow einen Base-SHA festlegt.
- `config.base_ref` ist ein additives Feld im vorhandenen State-Schema 2. Ein
  Schema-Bump oder eine Migration ist nicht erforderlich.
- Alte States ohne `config.base_ref` bleiben lesbar und fallen auf die
  bestehende Base-Auflösung zurück.
- Quick MVP bleibt zustandslos und akzeptiert keinen `--state`-Pfad.
- `blueprint/.repomethod/gitignore.template` ist die Quellform der installierten
  `.repomethod/.gitignore`. Es entsteht keine zweite Blueprint-Ignore-Datei.
- Das Repository erhält eine eigene committed `.repomethod/verify-command` mit
  genau `bats tests/*.bats` und eine `.repomethod/.gitignore` mit genau
  `*.tmp.*`. Beides macht den vorgegebenen Gate-/Invariant-Pfad aus einem
  kalten Checkout ausführbar und wird nicht in Ziel-Repositories installiert.
- Die Ausführungsfolge lautet `T1 -> {T3, T4 parallel} -> T5 -> T2`.

## Architecture and Authority Boundaries

### Base-Autorität

`workflow-graph.sh init` wählt genau einen Ref-Kandidaten und speichert dessen
Merge-Base mit `HEAD`. Der State speichert immer einen 40-stelligen
kleingeschriebenen SHA-1, nie einen Branchnamen. Konsumenten lesen den SHA und
lösen keinen neuen Base auf, solange ein gültiger State-Wert vorhanden ist.

Die Priorität für `agent-gate.sh` und `verify-scope.sh` ist:

1. explizites `--base <ref>`;
2. `config.base_ref` aus `--state <file>`;
3. bestehendes `resolve_base`.

Nur Fall 1 ruft `warn_if_base_not_ancestor` und `warn_if_base_stale` auf. Ein
aus State gelesener, während `init` berechneter SHA erzeugt keine
Stale-Warnung. `supervisor.sh` verwendet dieselbe Priorität. Ohne explizites
`--base` reicht es `--state` an seinen internen Scope-Check weiter.

### Preflight-Autorität

`preflight.sh` diagnostiziert nur die explizit festgelegte Umgebung. Es
installiert nichts, verändert keine Datei und führt `verify-command` nicht
aus. Es sammelt alle Befunde vor dem Exit.

Der Brief verlangt eine Prüfung der in `verify-command` genannten
Paketmanager und verbietet zugleich Stack- oder Paketmanager-Erkennung. Die
einzige syntaktische, nicht-ratende Form ist deshalb festgelegt: Von jeder
aktiven Zeile wird nur der erste whitespace-getrennte Command-Token geprüft.
Damit werden direkt aufgerufene Paketmanager erfasst. Shell-Ketten, Wrapper,
Variablenzuweisungen und Kommandos hinter `env`, `bash -c`, `cd`, `&&`, `|`
oder `;` werden nicht analysiert. Der Worker baut keine Namensliste und keine
Mapping-Tabelle. Diese Vereinfachung prüft den direkten Verify-Runner auch
dann, wenn er kein Paketmanager ist; sie ersetzt keine Stack-Erkennung.

### Delivery-Autorität

`deliver.sh` berechnet keinen Gate- oder Workflow-Zustand. Es ruft die
vorhandenen Aggregate auf, erfasst deren Ausgabe und übersetzt deren
Exitstatus beziehungsweise Supervisor-`verdict` in genau eine Zeile. Der
Supervisor-JSON-Wert `.reason` ist für stateful Delivery die Begründungsquelle.

## Dependencies and Interfaces

- T1 erzeugt die optionale State-Schnittstelle `config.base_ref` und
  `--state`, die T5 konsumiert.
- T3 und T4 beginnen nach abgeschlossenem T1. Sie verändern keine gemeinsamen
  Dateien und dürfen parallel laufen.
- T5 beginnt nach T1, T3 und T4.
- T2 beginnt nach T5. Es verändert vorhandene Warnlogik zuletzt, damit T4s
  Preflight-Reihenfolge bereits feststeht.
- Jeder Worker schreibt zuerst die benannten Tests, führt den fokussierten
  Bats-Befehl aus und dokumentiert den erwarteten RED-Grund. Erst danach darf
  er Implementierungsdateien ändern.
- Jeder Worker führt vor dem Handoff `/ponytail full` aus, sofern verfügbar.
  Ohne Skill prüft er manuell: keine neue Standardbibliothek, kein neues
  Script wenn ein Flag reicht, keine Abstraktion mit einem Caller, keine
  Config-Datei für einen unveränderlichen internen Wert.

## Scope

- `.repomethod/.gitignore`
- `.repomethod/verify-command`
- `blueprint/.repomethod/AGENTS.md`
- `blueprint/.repomethod/docs/WORKFLOW_GRAPH.md`
- `blueprint/.repomethod/gitignore.template`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/scripts/deliver.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/preflight.sh`
- `blueprint/.repomethod/scripts/supervisor.sh`
- `blueprint/.repomethod/scripts/verify-scope.sh`
- `blueprint/.repomethod/scripts/verify.sh`
- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/skills/classic-loop/SKILL.md`
- `blueprint/.repomethod/skills/graph-delivery/SKILL.md`
- `blueprint/.repomethod/skills/quick-mvp/SKILL.md`
- `blueprint/.repomethod/skills/repo-onboarding/SKILL.md`
- `tests/blueprint_agent_gate.bats`
- `tests/blueprint_deliver.bats`
- `tests/blueprint_preflight.bats`
- `tests/blueprint_verify_command.bats`
- `tests/blueprint_verify_scope.bats`
- `tests/install_basic.bats`
- `tests/supervisor.bats`
- `tests/workflow_baseline.bats`
- `tests/workflow_graph.bats`

## Out of Scope

- Änderungen außerhalb der einzeln aufgelisteten Scope-Pfade.
- Neue Laufzeitabhängigkeiten, Netzwerkzugriff, Modelle oder CI-spezifische
  Script-Zweige.
- State-Schema-Bump, State-Migration, `config.base_resolved_from` oder eine
  `.repomethod/base-ref` für Quick MVP.
- Stack-Erkennung, Lockfile-Erkennung, Paketmanager-Namenslisten,
  Sprach-/Glob-zu-Kommando-Tabellen oder Shell-Parsing von
  `verify-command`-Zeilen.
- `coverage-map.txt`, zusätzliche Coverage-Heuristik, ein harter
  `COVERAGE-GAP` oder eine Änderung der allgemeinen Spec-Vorlage.
- Statisches Scannen von Invariant-Zeilen nach `>`, `>>`, `tee` oder
  Output-Flags.
- Weitere `plan_persisted`-Ausnahmen im Supervisor.
- Auto-Fix, Dependency-Installation, Shell-Aktivierung oder weitere
  Preflight-Prüfungen.
- Eigene Scope-, Gate-, Evidence- oder Workflow-Bewertung in `deliver.sh`.
- Entfernung oder Verhaltensänderung der direkten Baustein-Aufrufe
  `agent-gate.sh` und `supervisor.sh`.
- Changelog-, Release-, Installer- oder README-Änderungen.

## Acceptance Criteria

1. `classic init` und `graph init` speichern `config.base_ref` als
   40-stelligen SHA. State-aware Gate, Scope und Supervisor verwenden diesen
   SHA ohne `--base`. Ein State ohne Feld fällt ohne Crash auf `resolve_base`
   zurück; explizites `--base` behält Vorrang und Warnungen.
2. Die vorhandene Frontend-Coverage-Warnung erscheint bytegleich bei
   `classic|graph init` und `agent-gate.sh --spec`. Die Warnung ändert keinen
   Exitstatus und erscheint weder bei Quick MVP noch ohne passenden Diff.
3. Die installierte `.repomethod/.gitignore` ignoriert
   `evidence/*.scratch`. `verify` und `reverify` verwenden ohne
   `--evidence` einen `.txt`-Default und behalten das vorhandene `git add -f`.
4. `preflight.sh` sammelt harte Befunde und Warnungen in einem Block. Ohne
   `jq` und ohne konfigurierte `verify-command` erscheinen beide harten
   Befunde vor Exit 1. `classic init` zeigt denselben Block vor jedem
   `jq`-Fehler. Eine vollständige Umgebung endet mit Exit 0.
5. Quick, Spec-only und Spec-plus-State verwenden `deliver.sh` und erzeugen
   genau eine Zeile `DELIVERY: done|blocked|incomplete — <reason>`. Nur `done`
   hat Exit 0. Die drei Delivery-Skills und der Close-out-Vertrag in
   `AGENTS.md` nennen ausschließlich `deliver.sh` als Close-out-Kommando.

## Acceptance Mapping

A backtick cell in `Test/Evidence` is enforced by the gate: a path under
`.repomethod/evidence/` must exist and be non-empty, and any other token
(a test name) must appear literally in an evidence file. Free text or an
`<placeholder>` stays a checkbox-only check.

| Criterion | Test/Evidence | Work Packet |
| --- | --- | --- |
| 1 | `classic state pins base_ref and all state consumers use it` | T1 |
| 2 | `coverage warning text and exit status match at init and spec gate` | T2 |
| 3 | `verify defaults to force-staged txt evidence` | T3 |
| 4 | `preflight reports jq and verify-command failures together` | T4 |
| 5 | `deliver prints one normalized line for quick and classic` | T5 |

## Work Packets

### T1: Base-Ref einmalig pinnen und state-aware konsumieren

#### Objective

Jeder neue Classic-/Graph-State enthält den beim `init` berechneten Fork-Punkt,
und alle späteren Scope-Entscheidungen verwenden ihn ohne erneute Heuristik.

#### Dependencies

- keine; T1 läuft zuerst.

#### Files

- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/scripts/verify-scope.sh`
- `blueprint/.repomethod/scripts/supervisor.sh`
- `blueprint/.repomethod/skills/classic-loop/SKILL.md`
- `blueprint/.repomethod/skills/graph-delivery/SKILL.md`
- `blueprint/.repomethod/docs/WORKFLOW_GRAPH.md`
- `blueprint/.repomethod/AGENTS.md`
- `tests/workflow_graph.bats`
- `tests/workflow_baseline.bats`
- `tests/blueprint_agent_gate.bats`
- `tests/blueprint_verify_scope.bats`
- `tests/supervisor.bats`

#### Exact CLI and state contract

1. `workflow-graph.sh init` ergänzt genau die Option `--base <ref>`. Ein
   fehlender Wert endet mit Exit 1 und `--base requires a value`.
2. Die Ref-Auswahl erfolgt genau einmal und in dieser Reihenfolge:
   - Wenn `--base` gesetzt ist, ist dieser Ref der einzige Kandidat. Kann
     `git merge-base HEAD <ref>` nicht genau einen SHA liefern, endet `init`
     mit Exit 1 und `cannot resolve explicit base ref: <ref>`. Es gibt keinen
     automatischen Fallback.
   - Sonst wird `@{upstream}` nur verwendet, wenn es auflösbar ist und der
     Teil nach dem ersten `/` nicht dem aktuellen Branchnamen entspricht.
     Damit bleibt ein selbst-trackender `origin/<current>` ausgeschlossen.
   - Danach wird das Ziel von `refs/remotes/origin/HEAD` versucht.
   - Danach wird `main` versucht.
   - Ein automatisch gewählter Kandidat, dessen `merge-base` nicht auflösbar
     ist, wird übersprungen. Wenn keiner funktioniert, endet `init` mit Exit 1
     und `cannot resolve a base ref — pass --base <ref>`.
3. Der Output von `git merge-base HEAD <ref>` muss `^[0-9a-f]{40}$` erfüllen.
   Andernfalls endet `init` mit Exit 1 und
   `base ref did not resolve to a 40-character commit SHA`. SHA-256-Git-Repos
   sind damit in dieser Änderung nicht unterstützt; der Brief verlangt
   ausdrücklich 40 Zeichen.
4. Das Initial-State-JSON erhält innerhalb von `config` genau
   `"base_ref":"<sha>"`. `schema_version` bleibt 2. Kein weiteres Base-Feld
   wird geschrieben.
5. `feature-workflow.sh classic init` und `graph init` bestimmen aus ihren
   vorhandenen Argumenten den tatsächlichen State-Pfad und normalisieren nur
   das kanonische Gate-Kommando:
   `.repomethod/scripts/agent-gate.sh --spec <spec-path>`.
   - Beginnt der übergebene `--verify-command` mit dieser kanonischen Form und
     enthält er weder ` --state ` noch ` --base `, wird genau
     ` --state <shell-quoted-actual-state-path>` angehängt.
   - Enthält ein kanonisches Gate-Kommando bereits `--state` oder `--base`,
     endet `init` mit Exit 1 und
     `agent-gate verify command must omit --state and --base; init records the actual state`.
   - Andere Verify-Kommandos wie `true`, `make test` oder ein eigener Wrapper
     bleiben bytegleich.
   - Der tatsächliche State-Pfad ist der Wert von `--state`; ohne Flag ist er
     `.repomethod/workflows/<feature>.json`. Für Shell-Quoting wird Bash
     `printf %q` verwendet, kein eigener Escaper.
6. Der Wrapper ersetzt nur den Wert des vorhandenen `--verify-command`-Paars
   in seiner Argumentliste und leitet alle übrigen Argumente unverändert an
   `workflow-graph.sh init` weiter. `workflow-graph.sh` selbst speichert den
   übergebenen String bytegleich. Die Hilfetexte zeigen das kanonische
   Gate-Kommando ohne `--state` und ohne `--base`, weil der Wrapper den State
   ergänzt.
7. `agent-gate.sh` akzeptiert im Full-Gate `--state <file>`. `--quick
   --state` ist ungültig und endet mit Exit 1 und
   `--state is only valid with --spec`.
8. `verify-scope.sh` akzeptiert im Full-Modus `--state <file>`. `--quick
   --state` ist ebenfalls ungültig. `--state` muss auf eine lesbare JSON-Datei
   zeigen; sonst Exit 1 mit `state not found: <file>`.
9. Für beide Konsumenten gilt nach Argument-Parsing:
   - Wenn `--base` gesetzt ist, wird der Wert verwendet. Ein zugleich
     gesetztes `--state` darf vorhanden sein, wird für Base aber ignoriert.
   - Ohne `--base` und mit State wird `.config.base_ref // empty` gelesen.
   - Ein leerer oder fehlender Wert ruft das bestehende `resolve_base` auf.
   - Ein nichtleerer State-Wert, der nicht `^[0-9a-f]{40}$` erfüllt oder in
     `--repo` nicht als Commit auflösbar ist, endet mit Exit 1 und
     `invalid config.base_ref in state: <value>`. Er fällt nicht still zurück.
10. `agent-gate.sh --spec` übergibt `--state` an `verify-scope.sh`, solange
    kein explizites `--base` gesetzt ist. Mit explizitem Base übergibt es nur
    `--base`.
11. `supervisor.sh` liest ohne explizites `--base` zuerst
    `.config.base_ref // empty`. Fehlend/leer nutzt `resolve_base`; ungültig
    erzeugt dieselbe Fehlermeldung wie oben. Sein interner Full-Scope-Aufruf
    lautet ohne explizites Base `verify-scope.sh --spec <spec> --state <state>
    --repo .`; mit explizitem Base verwendet er `--base <ref>`.
12. `warn_if_base_not_ancestor` und `warn_if_base_stale` laufen nur, wenn der
    Aufrufer explizit `--base` gesetzt hat. Das bestehende Warnungsformat
    bleibt unverändert.
13. `classic-loop/SKILL.md`, `graph-delivery/SKILL.md` und
    `AGENTS.md` zeigen keine Happy-Path-Option `--base`. Sie zeigen auch kein
    manuelles `--state` im gespeicherten Gate-Kommando.
14. `WORKFLOW_GRAPH.md` erhält genau die Aussage, dass Quick MVP keinen State
    erzeugt und seinen Base deshalb bei jedem Gate mit `resolve_base` bestimmt.

#### Exact test matrix

Alle folgenden Testnamen werden wörtlich verwendet:

- `tests/workflow_graph.bats`
  - `init pins an explicit merge base as a 40-character SHA`
  - `init chooses foreign upstream then origin HEAD then main`
  - `init rejects an invalid explicit base without fallback`
  - `init leaves a non-gate verification command byte-identical`
- `tests/workflow_baseline.bats`
  - `classic and graph init persist a state-aware canonical gate command`
- `tests/blueprint_verify_scope.bats`
  - `--state uses base_ref and missing base_ref falls back`
  - `explicit --base wins over --state and keeps diagnostics`
  - `invalid state base_ref fails instead of falling back`
- `tests/blueprint_agent_gate.bats`
  - `agent gate forwards state base_ref without a base flag`
  - `quick gate rejects state`
- `tests/supervisor.bats`
  - `classic state pins base_ref and all state consumers use it`
  - `supervisor falls back for a legacy state without base_ref`

Der Acceptance-Test baut folgende Git-Historie: Commit A auf `main`; Branch
`feature-base` mit einem out-of-scope Commit B; `origin/HEAD` zeigt auf
`feature-base`; Branch `work` ohne Upstream mit einem in-scope Commit C. Der
bei `init` gespeicherte SHA muss B sein. Gate und Supervisor dürfen B nicht als
Änderung von `work` melden. Danach wird nur `config.base_ref` aus einer Kopie
des States entfernt; der erneute Aufruf darf nicht crashen.

#### RED, GREEN, handoff

- RED-Befehl:
  `bats tests/workflow_graph.bats tests/workflow_baseline.bats tests/blueprint_verify_scope.bats tests/blueprint_agent_gate.bats tests/supervisor.bats`
- Erwartetes RED: `workflow-graph.sh init` kennt `--base`/`base_ref` noch nicht
  oder `agent-gate.sh` lehnt `--state` ab.
- GREEN ist derselbe Bats-Befehl mit allen genannten Tests grün.
- Shellcheck:
  `shellcheck blueprint/.repomethod/scripts/workflow-graph.sh blueprint/.repomethod/scripts/feature-workflow.sh blueprint/.repomethod/scripts/verify-scope.sh blueprint/.repomethod/scripts/agent-gate.sh blueprint/.repomethod/scripts/supervisor.sh`
- Stoppe statt zu implementieren, sobald ein Schema-Bump, eine Migration, eine
  zweite Base pro State oder ein neuer Runtime-Dependency nötig wird.

### T3: Evidence-Default und Ignore-Rest korrigieren

#### Objective

Verification-Evidence erhält ohne Aufruferwahl einen committable `.txt`-Pfad,
und Scratch-Evidence bleibt in installierten Repositories ignoriert.

#### Dependencies

- T1 abgeschlossen; T3 darf parallel zu T4 laufen.

#### Files

- `blueprint/.repomethod/gitignore.template`
- `blueprint/.repomethod/scripts/workflow-graph.sh`
- `tests/workflow_graph.bats`
- `tests/install_basic.bats`

#### Exact behavior

1. `blueprint/.repomethod/gitignore.template` erhält genau die neue Zeile
   `evidence/*.scratch`. Die vorhandene globale `*.tmp.*`-Zeile und alle
   Supervisor-Regeln bleiben unverändert.
2. `workflow-graph.sh` dokumentiert `--evidence <file>` bei `verify` und
   `reverify` als optional.
3. Nach `load_state` und vor der bisherigen `--evidence is required`-Stelle
   wird nur für `verify|reverify` ein leerer Evidence-Wert gesetzt auf:
   `<repo-root>/.repomethod/evidence/<feature>-<node>.txt`.
4. `<repo-root>` wird mit derselben vorhandenen Regel wie in
   `_run_verification_into_evidence` bestimmt: Git-Root aus dem State-Verzeichnis,
   sonst `.repo_root` aus State. Es wird kein neuer Root-Resolver erstellt.
5. Für Feature `demo` und Node `verification` ist der Default exakt
   `.repomethod/evidence/demo-verification.txt`. Für Retry-Node
   `verification-2` ist er `demo-verification-2.txt`.
6. `reverify` verwendet für denselben Feature-/Node-Wert denselben Pfad und
   überschreibt die Datei wie bisher.
7. Ein explizites `--evidence` hat unverändert Vorrang, auch wenn es `.log`
   oder außerhalb `.repomethod/evidence` endet.
8. `_run_verification_into_evidence` und sein bestehendes
   `git -C <root> add -f -- <path>` bleiben die einzige Schreib-/Stage-Logik.
9. Es gibt keine statische Invariant-Analyse und keine Supervisor-Änderung.

#### Exact test matrix

- `tests/install_basic.bats`
  - `installed gitignore ignores evidence scratch files`
    installiert den Blueprint in ein Temp-Repository und prüft
    `git check-ignore -q .repomethod/evidence/x.scratch`.
- `tests/workflow_graph.bats`
  - `verify defaults to force-staged txt evidence`
    verwendet Root-`.gitignore` `*.log`, ruft `verify` ohne `--evidence` auf,
    prüft Inhalt und `git status --porcelain` auf
    `A  .repomethod/evidence/demo-verification.txt`.
  - `reverify reuses the default txt evidence path`
  - `explicit verification evidence path still wins`

#### RED, GREEN, handoff

- RED-Befehl: `bats tests/workflow_graph.bats tests/install_basic.bats`
- Erwartetes RED: `verify` endet mit `--evidence is required`; der installierte
  Scratch-Pfad wird nicht ignoriert.
- GREEN ist derselbe Befehl.
- Shellcheck: `shellcheck blueprint/.repomethod/scripts/workflow-graph.sh`
- Kein neues Script, keine neue Helper-Datei und keine Supervisor-Änderung.

### T4: Einen deterministischen Umgebungs-Preflight einführen

#### Objective

Classic, Graph und das Aggregate Gate melden alle festgelegten
Umgebungsprobleme gesammelt, bevor ein späteres Tool mit einer verstreuten
Fehlermeldung abbricht.

#### Dependencies

- T1 abgeschlossen; T4 darf parallel zu T3 laufen.

#### Files

- `.repomethod/.gitignore`
- `.repomethod/verify-command`
- `blueprint/.repomethod/scripts/preflight.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `blueprint/.repomethod/skills/repo-onboarding/SKILL.md`
- `tests/blueprint_preflight.bats`
- `tests/workflow_baseline.bats`
- `tests/blueprint_agent_gate.bats`

#### Exact invocation contract

1. Neues ausführbares Script:
   `.repomethod/scripts/preflight.sh [--quiet]` im installierten Layout und
   `blueprint/.repomethod/scripts/preflight.sh [--quiet]` im Quelllayout.
2. Kein Positionsargument und kein zweiter Flag ist erlaubt. Unbekannte oder
   zusätzliche Argumente ergeben Exit 2 und genau
   `usage: preflight.sh [--quiet]` auf stderr.
3. Der Repository-Root ist `git rev-parse --show-toplevel` aus dem aktuellen
   Arbeitsverzeichnis. Schlägt nur diese Root-Ermittlung fehl, wird `pwd -P`
   verwendet; es entsteht dafür kein zusätzlicher Befund.
4. Die Konfiguration ist immer `<repo-root>/.repomethod/verify-command`.
   Das Quellrepository erhält deshalb die committed Datei
   `.repomethod/verify-command` mit exakt einer Zeile:
   `bats tests/*.bats`.
5. Das Quellrepository erhält außerdem `.repomethod/.gitignore` mit exakt
   `*.tmp.*`. Damit sind die vorgeschriebenen Pfade
   `.repomethod/evidence/preflight.tmp.txt` und `suite.tmp.txt` aus committed
   Zustand ignoriert. Es wird keine Root-`.gitignore` geändert.
6. Das Script muss unter Bash 3 noch bis zur Versionsmeldung laufen können.
   Es verwendet vor dem Bash-4-Check kein `mapfile`, keine assoziativen Arrays
   und keine Bash-4-only-Syntax.

#### Exact findings and order

Das Script sammelt Befunde in dieser Reihenfolge und druckt sie später in
derselben Reihenfolge:

1. Bash-Version:
   - hart, wenn Major kleiner 4;
   - Zeile:
     `HARD: bash 4.0+ required (current: <major>.<minor>) | FIX: run RepoMethod with bash 4.0 or newer`.
2. Git-Version:
   - hart, wenn `git` fehlt oder Major/Minor kleiner 2.20;
   - bei vorhandenem Git wird aus `git --version` die erste numerische
     `<major>.<minor>[.<patch>]`-Folge gelesen und Major/Minor numerisch
     verglichen; ein nicht parsebarer Output wird wie `missing` behandelt;
   - fehlend:
     `HARD: git 2.20+ required (current: missing) | FIX: install git 2.20 or newer`;
   - zu alt:
     `HARD: git 2.20+ required (current: <version>) | FIX: install git 2.20 or newer`.
3. `jq`:
   - hart, wenn `command -v jq` fehlschlägt;
   - Zeile:
     `HARD: jq not found | FIX: install jq and put it on PATH`.
4. Verify-Konfiguration:
   - fehlende Datei, hart:
     `HARD: .repomethod/verify-command missing | FIX: create it with one verification command per active line`;
   - keine nichtleere, nicht mit optionalem Whitespace plus `#` beginnende
     Zeile, hart:
     `HARD: .repomethod/verify-command has no active command | FIX: add at least one non-comment command`.
5. Direkte Verify-Runner:
   - nur wenn mindestens eine aktive Zeile existiert;
   - vor der Token-Bildung wird führender Whitespace entfernt; Token ist dann
     die Zeichenfolge bis zum nächsten Whitespace;
   - pro erstmalig auftretendem Token, das `command -v` nicht findet, ein
     harter Befund in Zeilenreihenfolge:
     `HARD: verify-command program '<token>' not found | FIX: install '<token>' or correct .repomethod/verify-command`;
   - Duplikate werden einmal gemeldet. Es gibt keine Shell-Auswertung und
     keine Sonderbehandlung von `env`, Assignments oder Operatoren.
6. Detached HEAD:
   - Warnung, wenn Git vorhanden ist und
     `git symbolic-ref -q HEAD` fehlschlägt;
   - Zeile:
     `WARN: HEAD is detached | FIX: check out the intended branch before starting a workflow`.
7. Fremde Venv:
   - Projekt-Venv ist der konstante Pfad `<repo-root>/.venv`;
   - Warnung nur bei nichtleerem `VIRTUAL_ENV`, dessen physisch
     normalisierter Pfad nicht dem physisch normalisierten Projektpfad
     entspricht. Ein noch nicht existierender Projektpfad wird lexikalisch
     als `<repo-root>/.venv` verglichen;
   - Zeile:
     `WARN: VIRTUAL_ENV is not <repo-root>/.venv | FIX: deactivate it or activate <repo-root>/.venv`.
8. `node_modules`-Symlinks:
   - Suche unter `<repo-root>`, aber prune `<repo-root>/.git`; ein Treffer ist
     ein Pfad mit `-type l` und Basename `node_modules`;
   - ein Warnbefund je relativem Pfad, lexikographisch sortiert;
   - Zeile:
     `WARN: node_modules symlink at <relative-path> | FIX: remove it or keep the path covered by .repomethod/scope-ignore.txt`.

`<repo-root>` in Ausgaben ist der absolute normalisierte Root-Pfad. Das Script
prüft nichts außerhalb dieser Liste.

#### Exact output and exit contract

1. Normaler Aufruf mit null Befunden druckt genau
   `PREFLIGHT: 0 problem(s)` und endet 0.
2. Normaler Aufruf mit Befunden druckt zuerst
   `PREFLIGHT: <hard+warning count> problem(s)`, danach jede Befundzeile. Er
   endet 1, wenn mindestens ein harter Befund existiert, sonst 0.
3. `--quiet` entfernt alle Warnungen vor Zählung und Ausgabe.
4. `--quiet` mit null harten Befunden druckt nichts und endet 0.
5. `--quiet` mit harten Befunden druckt Header plus alle harten Befunde und
   endet 1.
6. Das Script schreibt keine Datei und startet kein genanntes Verify-Kommando.

#### Integration points

1. `feature-workflow.sh classic init` und `graph init` rufen als erste
   Seiteneffekt-freie Prüfung `preflight.sh` ohne `--quiet` auf. Die endgültige
   Reihenfolge ist: Preflight, dann `assert_baseline_green` (T2 emittiert darin
   unmittelbar vor `verify-command` die optionale Coverage-Warnung), dann
   `workflow-graph.sh init`.
2. Bei Preflight-Exit ungleich 0 beendet `feature-workflow.sh` sich mit
   demselben Exitstatus. Es druckt keinen zusätzlichen Prefix und erstellt
   keinen State.
3. `quick-mvp` ruft den Preflight beim Start nicht auf; sein Close-out läuft
   später über den Gate-Pfad.
4. `agent-gate.sh` ruft nach Argument-Validierung, aber vor Base-Auflösung und
   vor `verify.sh`, genau `preflight.sh --quiet` auf. Das gilt für `--quick`
   und `--spec`.
5. `repo-onboarding/SKILL.md` setzt
   `.repomethod/scripts/preflight.sh` als Schritt 1 vor das Erzeugen/Lesen der
   Project Map. Bei hartem Befund stoppt Onboarding.

#### Exact test matrix

- `tests/blueprint_preflight.bats`
  - `preflight reports jq and verify-command failures together`
  - `preflight succeeds with a complete environment`
  - `preflight warnings keep exit zero`
  - `preflight quiet suppresses warnings and green output`
  - `preflight reports every missing direct verify runner once`
  - `preflight rejects unknown arguments with usage exit two`
  - `preflight source file is executable`
- `tests/workflow_baseline.bats`
  - `classic init aborts with the preflight block before jq`
  - `graph init runs baseline only after a green preflight`
- `tests/blueprint_agent_gate.bats`
  - `agent gate quiet preflight aborts before every gate`

Der No-`jq`-Test baut einen Temp-`PATH`, der Bash, Git, `grep`, `find`, `sort`
und weitere verwendete Standardprogramme bereitstellt, aber kein `jq`. Die
Fixture enthält keine `.repomethod/verify-command`. Erwartet werden genau zwei
harte Befunde für `jq` und die fehlende Verify-Datei; der Test muss verhindern,
dass ein fehlendes Fixture-Programm zusätzliche Befunde erzeugt.

#### RED, GREEN, handoff

- RED-Befehl:
  `bats tests/blueprint_preflight.bats tests/workflow_baseline.bats tests/blueprint_agent_gate.bats`
- Erwartetes RED: `preflight.sh` und die Root-`verify-command` fehlen.
- GREEN ist derselbe Befehl.
- Shellcheck:
  `shellcheck blueprint/.repomethod/scripts/preflight.sh blueprint/.repomethod/scripts/feature-workflow.sh blueprint/.repomethod/scripts/agent-gate.sh`
- Zusätzlich:
  `test -x blueprint/.repomethod/scripts/preflight.sh` und
  `test "$(cat .repomethod/verify-command)" = "bats tests/*.bats"` sowie
  `git check-ignore -q .repomethod/evidence/preflight.tmp.txt`.
- Kein Helper-Script, keine Installation und keine weitere Prüfung ergänzen.

### T5: Eine reine Close-out-Fassade einführen

#### Objective

Alle drei Delivery-Pfade liefern über ein Kommando genau eine normalisierte
Ergebniszeile, während Gate und Supervisor die einzige fachliche Autorität
bleiben.

#### Dependencies

- T1, T3 und T4 abgeschlossen.

#### Files

- `blueprint/.repomethod/scripts/deliver.sh`
- `blueprint/.repomethod/skills/quick-mvp/SKILL.md`
- `blueprint/.repomethod/skills/classic-loop/SKILL.md`
- `blueprint/.repomethod/skills/graph-delivery/SKILL.md`
- `blueprint/.repomethod/AGENTS.md`
- `tests/blueprint_deliver.bats`

#### Exact CLI contract

Erlaubt sind genau:

- `deliver.sh --quick`
- `deliver.sh --spec <spec>`
- `deliver.sh --spec <spec> --state <state>`

`--state` darf vor oder nach `--spec` stehen. Jeder Flag kommt höchstens
einmal vor. `--quick` darf mit keinem anderen Flag kombiniert werden. Fehlende
Werte, Duplikate, unbekannte Flags oder kein Modus ergeben Exit 1 und genau:

`DELIVERY: blocked — usage: deliver.sh --quick | --spec <spec> [--state <state>]`

Diese Zeile geht auf stdout. `deliver.sh` schreibt nie auf stderr.

#### Exact dispatch and status table

1. Unterkommandos werden mit kombiniertem stdout/stderr erfasst. Ihre Ausgabe
   wird nie direkt weitergereicht.
2. `--quick` ruft exakt `agent-gate.sh --quick` auf.
3. `--spec <s>` ruft exakt `agent-gate.sh --spec <s>` auf.
4. `--spec <s> --state <f>` ruft zuerst exakt
   `agent-gate.sh --spec <s> --state <f>` auf. Nur bei Exit 0 folgt exakt
   `supervisor.sh check --state <f>`.
5. Gate-Ergebnis:

| Path | Upstream result | Delivery line | Exit |
| --- | --- | --- | --- |
| quick | agent-gate exit 0 | `DELIVERY: done — quick gate passed` | 0 |
| spec without state | agent-gate exit 0 | `DELIVERY: done — spec gate passed` | 0 |
| any | agent-gate exit nonzero | `DELIVERY: blocked — <gate-reason>` | 1 |

6. `<gate-reason>` ist die letzte nichtleere Zeile der erfassten kombinierten
   Gate-Ausgabe. Führende und folgende Whitespaces werden entfernt. Enthält
   die Zeile CR oder LF, werden diese durch `; ` ersetzt. Gibt es keine
   nichtleere Zeile, lautet sie `agent-gate exited <status>`.
7. Nach grünem stateful Gate muss die Supervisor-Ausgabe als ein einzelnes
   JSON-Objekt mit Stringfeldern `.verdict` und `.reason` durch `jq -e`
   validieren. Danach gilt:

| Supervisor verdict | Required supervisor exit | Delivery line | Deliver exit |
| --- | --- | --- | --- |
| `done` | 0 | `DELIVERY: done — <reason>` | 0 |
| `continue` | 10 | `DELIVERY: incomplete — <reason>` | 1 |
| `blocked` | 2 | `DELIVERY: blocked — <reason>` | 1 |
| `needs_human` | 3 | `DELIVERY: blocked — <reason>` | 1 |
| `evidence-ignored` | 4 | `DELIVERY: blocked — <reason>` | 1 |

8. Stimmen Supervisor-Verdict und Exitstatus nicht überein, ist JSON ungültig,
   fehlt `.reason` oder ist `.reason` leer, lautet das Ergebnis Exit 1 und
   `DELIVERY: blocked — invalid supervisor result`.
9. Supervisor-Reason wird auf eine Ausgabezeile normalisiert: CR/LF-Sequenzen
   werden `; `, führender/folgender Whitespace entfällt. Sonst bleibt der Text
   bytegleich.
10. Es gibt keine weitere Statuskategorie und keine Wiederholung eines
    fehlgeschlagenen Unterkommandos.

#### Documentation contract

1. `quick-mvp/SKILL.md` nennt als Close-out genau
   `.repomethod/scripts/deliver.sh --quick`.
2. `classic-loop/SKILL.md` und `graph-delivery/SKILL.md` nennen als Close-out
   genau `.repomethod/scripts/deliver.sh --spec <spec> --state <file>`.
3. Die Skills dürfen `agent-gate.sh` weiterhin innerhalb des bei `init`
   gespeicherten `--verify-command` nennen. Sie dürfen keinen direkten
   `agent-gate.sh`-/`supervisor.sh`-Aufruf als letzten Delivery-Schritt nennen.
4. `AGENTS.md` zeigt im Verification-Kommandoblock weiterhin die Bausteine,
   ersetzt aber alle Aussagen „close out“, „delivery is confirmed“ und
   „before declaring delivery complete“ durch die passende `deliver.sh`-Form.
5. T5 verändert `agent-gate.sh`, `supervisor.sh` und `feature-workflow.sh`
   nicht.

#### Exact test matrix

`tests/blueprint_deliver.bats` enthält genau diese Verhaltensfälle:

- `deliver prints one normalized line for quick and classic`
- `deliver maps an incomplete classic workflow to exit one`
- `deliver maps every terminal supervisor verdict`
- `deliver blocks on a red gate without calling supervisor`
- `deliver rejects invalid flag combinations with one line`
- `deliver rejects malformed or inconsistent supervisor output`
- `delivery skills use deliver only for close-out`
- `deliver source file is executable`

Die Tests verwenden Fixture-Skripte für Gate und Supervisor, um jede
Statuszeile deterministisch abzudecken. Der erste Acceptance-Test enthält
zusätzlich je einen realen Quick- und Classic-Happy-Path mit kopierten
Blueprint-Skripten. Vor jedem realen Gate-Fixture existiert eine aktive
`.repomethod/verify-command`, damit T4 nicht den getesteten T5-Pfad verdeckt.

#### RED, GREEN, handoff

- RED-Befehl: `bats tests/blueprint_deliver.bats`
- Erwartetes RED: `deliver.sh` fehlt und Skills nennen direkte Bausteine.
- GREEN ist derselbe Befehl.
- Shellcheck: `shellcheck blueprint/.repomethod/scripts/deliver.sh`
- Zusätzlich: `test -x blueprint/.repomethod/scripts/deliver.sh`.
- Keine Helper-Datei, keine Statusaggregation und keine Änderung der
  aufgerufenen Bausteine.

### T2: Vorhandene Coverage-Warnung bis zum Spec-Gate propagieren

#### Objective

Die vorhandene, nicht-blockierende Frontend-Warnung erscheint beim Init und
unmittelbar vor einem Full-Gate mit identischem Text und identischer
Erkennung.

#### Dependencies

- T1, T3, T4 und T5 abgeschlossen; T2 läuft zuletzt.

#### Files

- `blueprint/.repomethod/scripts/verify.sh`
- `blueprint/.repomethod/scripts/feature-workflow.sh`
- `blueprint/.repomethod/scripts/agent-gate.sh`
- `tests/blueprint_verify_command.bats`
- `tests/workflow_baseline.bats`
- `tests/blueprint_agent_gate.bats`

#### Exact behavior

1. `verify.sh` akzeptiert genau die neue optionale Form:
   `verify.sh [--warn-frontend-uncovered] [repo-dir]`.
2. Der bestehende Aufruf `verify.sh <repo-dir>` bleibt bytegleich im Verhalten.
   Unbekannte Flags oder mehr als ein Repo-Pfad enden mit Exit 1 und der
   bestehenden Verify-Fehlerschnittstelle.
3. `_warn_frontend_uncovered` wandert aus `feature-workflow.sh` nach
   `verify.sh`. Es bleibt genau ein Helper mit genau dieser Logik:
   - Verify-Datei ist `<repo-dir>/.repomethod/verify-command`;
   - fehlt die Datei, return 0 ohne Ausgabe;
   - Changed-Set ist die sortierte Vereinigung aus
     `git diff --name-only`, `git diff --cached --name-only` und
     `git ls-files --others --exclude-standard` im Repo;
   - Frontend-Suffixe bleiben exakt `.ts`, `.tsx`, `.js`, `.jsx`;
   - JS-Check-Tokens bleiben exakt
     `pnpm|npm|npx|vitest|jest|tsc|eslint` auf nicht kommentierten
     Verify-Zeilen;
   - Warntext bleibt exakt
     `WARN: change touches frontend files but verify-command runs no JS check`
     auf stderr;
   - jeder interne Fehler der Heuristik wird als „keine Warnung“ behandelt und
     verändert keinen Exitstatus.
4. Mit Flag läuft der Helper nach erfolgreicher Argumentauswertung und vor der
   Prüfung „verify-command konfiguriert“. Danach führt `verify.sh` unverändert
   alle aktiven Verify-Zeilen aus und gibt deren ersten nonzero Status zurück.
5. `feature-workflow.sh` entfernt seine lokale Helper-Definition und seinen
   separaten Aufruf. `assert_baseline_green` akzeptiert einen internen
   Boolean-Parameter. Classic-/Graph-`init` rufen den Baseline-Check so auf,
   dass er `verify.sh --warn-frontend-uncovered .` verwendet. Quick MVP ruft
   weiter `verify.sh .` ohne Flag auf.
6. `agent-gate.sh --spec` ruft nach grünem T4-Preflight
   `verify.sh --warn-frontend-uncovered .` auf. `--quick` ruft
   `verify.sh .` ohne Flag auf.
7. Der Warn-Helper wird pro öffentlichem Init-/Gate-Aufruf genau einmal
   ausgeführt. Es gibt kein neues Script und keine neue Detection.

Diese Form ersetzt die im Brief genannte „shared helper“-Datei durch einen
Flag am bereits zuständigen `verify.sh`. Sie hat einen Helper und zwei
öffentliche Call-Sites und vermeidet ein zusätzliches Script.

#### Exact test matrix

- `tests/blueprint_verify_command.bats`
  - `warning flag preserves verify command exit status`
  - `warning flag uses the existing frontend token set`
  - `verify without warning flag stays silent`
- `tests/workflow_baseline.bats`
  - `classic and graph init emit the shared frontend warning once`
- `tests/blueprint_agent_gate.bats`
  - `coverage warning text and exit status match at init and spec gate`
  - `quick gate does not emit the frontend coverage warning`

Der Acceptance-Test verwendet für beide öffentlichen Pfade dieselbe Fixture:
eine gestagte `src/app.tsx`, eine aktive Verify-Zeile `true` und keine
JS-Token-Zeile. Er extrahiert nur Zeilen mit dem exakten `WARN:`-Text und
vergleicht sie bytegleich. Danach ersetzt er `true` durch `echo pnpm test`
beziehungsweise ergänzt eine JS-Token-Zeile, ohne `pnpm` tatsächlich
auszuführen; die Warnung muss verschwinden und der Verify-Exitstatus muss
weiter vom ausgeführten Kommando stammen.

#### RED, GREEN, handoff

- RED-Befehl:
  `bats tests/blueprint_verify_command.bats tests/workflow_baseline.bats tests/blueprint_agent_gate.bats`
- Erwartetes RED: Das Spec-Gate kennt den Warn-Flag nicht und emittiert keine
  Warnung.
- GREEN ist derselbe Befehl.
- Shellcheck:
  `shellcheck blueprint/.repomethod/scripts/verify.sh blueprint/.repomethod/scripts/feature-workflow.sh blueprint/.repomethod/scripts/agent-gate.sh`.
- Benötigt die Umsetzung mehr als einen Helper in `verify.sh`, einen Flag und
  die zwei öffentlichen Call-Sites, wird T2 gestrichen und eskaliert.

## Definition of Minimal

T1 besteht aus einem additiven `config.base_ref`, einem `--state`-Read je
Konsument und der Normalisierung des bereits vorhandenen kanonischen
Gate-Kommandos; Telemetrie, Quick-MVP-Base-Datei, Schema-Bump und Migration
entfallen. T2 besteht aus einem Helper hinter einem `verify.sh`-Flag und zwei
öffentlichen Call-Sites; neue Detection, Coverage-Map, harter Abort und neues
Script entfallen. T3 ergänzt eine Ignore-Zeile und einen vorhandenen
Evidence-Default mit `.txt`; statische Schreibzielanalyse und Supervisor-Logik
entfallen. T4 besteht aus einem selbstständigen Script mit genau der
aufgezählten Befundsliste plus der Repository-eigenen bestehenden
`verify-command`-Schnittstelle; Helper-Auslagerung, Auto-Fix, Installation,
Stack-Erkennung und weitere Checks entfallen. T5 ist ein Dispatcher mit fester
Übersetzungstabelle und Ein-Zeilen-Ausgabe; eigene Aggregation, Retry,
fachliche Bewertung und Änderungen an Gate oder Supervisor entfallen.

## Verify Command

```bash
blueprint/.repomethod/scripts/agent-gate.sh --spec specs/cloud-local-continuity.md
```

## Integration Invariants

- `bash blueprint/.repomethod/scripts/preflight.sh > .repomethod/evidence/preflight.tmp.txt 2>&1; test $? -eq 0`
- `bats tests/*.bats > .repomethod/evidence/suite.tmp.txt 2>&1`
- `grep -q base_ref blueprint/.repomethod/scripts/agent-gate.sh blueprint/.repomethod/scripts/verify-scope.sh`
- `test -x blueprint/.repomethod/scripts/deliver.sh && test -x blueprint/.repomethod/scripts/preflight.sh`

## Expected Evidence

- `.repomethod/evidence/preflight.tmp.txt`
- `.repomethod/evidence/suite.tmp.txt`
- `.repomethod/evidence/report.md`

## Escalation Conditions

- Ein Paket benötigt eine neue Laufzeitabhängigkeit.
- T1 benötigt eine State-Schema-Migration oder einen Schema-Bump.
- `base_ref` kollidiert mit einem realen Multi-Base-Workflow in diesem
  Repository.
- Ein betroffener Pfad hat keine Bats-Abdeckung und die Suite müsste für seine
  Aufnahme restrukturiert werden.

Bei Eintritt einer Bedingung stoppt der Worker. Sein Handoff nennt Paket,
konkreten Konflikt, aktuellen RED-Test und den kleinsten bestätigten Shape. Er
ändert keinen zusätzlichen Pfad und baut keine Umgehung.

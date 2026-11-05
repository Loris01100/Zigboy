# Zigboy

[![CI](https://github.com/Loris01100/Zigboy/actions/workflows/ci.yml/badge.svg)](https://github.com/Loris01100/Zigboy/actions/workflows/ci.yml)

Émulateur Game Boy (DMG) écrit en Zig.

**Objectif :** pouvoir jouer à Pokémon Rouge, sauvegarder en jeu, fermer l'émulateur, puis reprendre la partie. On y arrive par étapes : cartouche et bus mémoire, CPU SM83, interruptions et timers, PPU, joypad (Tetris), puis MBC et sauvegardes. Le plan détaillé est dans [FEUILLE_DE_ROUTE.md](FEUILLE_DE_ROUTE.md).

## Version de Zig

**Zig 0.17.1**, épinglé dans `minimum_zig_version` de [build.zig.zon](build.zig.zon). La CI lit la version au même endroit. On ne change de version qu'entre deux phases.

## Commandes

```sh
zig build                   # compile l'exécutable dans zig-out/bin/
zig build run -- <rom.gb>   # lance l'émulateur sur une ROM
zig build test              # lance tous les tests (cœur et exécutable)
zig build sst               # SingleStepTests du CPU (voir plus bas)
zig build sst -- 27 cb37    # seulement certains opcodes (ici DAA et SWAP A)
zig fmt build.zig src tests # formate le code (la CI fait --check)
```

### SingleStepTests

[SingleStepTests sm83](https://github.com/SingleStepTests/sm83) : 1000 cas JSON par opcode (état avant, état après, M-cycles). Les données (160 Mo) ne sont pas versionnées. Pour les récupérer :

```sh
git clone --depth 1 https://github.com/SingleStepTests/sm83.git test-roms/sm83
```

Le harnais ([tests/sst.zig](tests/sst.zig)) branche le CPU sur une mémoire plate de 64 Kio, comme le demandent ces tests. Il affiche le détail du premier cas faux de chaque opcode. STOP (`10`) et HALT (`76`) sont ignorés par défaut : les données (issues d'Ares) les modélisent autrement que les Pan Docs. `zig build sst -- 10 76` les lance quand même.

### Gameboy Doctor

[Gameboy Doctor](https://github.com/robert/gameboy-doctor) compare l'état du CPU, instruction par instruction, à celui d'un émulateur de référence sur les ROMs `cpu_instrs` de Blargg. Récupération des outils :

```sh
git clone --depth 1 https://github.com/robert/gameboy-doctor.git test-roms/gameboy-doctor
git clone --depth 1 https://github.com/retrio/gb-test-roms.git test-roms/gb-test-roms
```

Puis, pour la ROM n° 3 par exemple :

```sh
zig build doctor -- "test-roms/gb-test-roms/cpu_instrs/individual/03-op sp,hl.gb" test-roms/logs/3.log
python test-roms/gameboy-doctor/gameboy-doctor test-roms/logs/3.log cpu_instrs 3
```

Le traceur ([tests/doctor.zig](tests/doctor.zig)) fait lire 0x90 à LY (0xFF44) et affiche aussi ce que la ROM écrit sur le port série (`Passed` ou `Failed`). `02-interrupts` ne peut pas passer avant la phase 3.

## Structure

```
src/
├── main.zig        # frontend : arguments, lecture de la ROM, affichage (plus tard)
└── gb/             # cœur de l'émulateur, module `gb`
    └── gameboy.zig # racine du module
```

Le cœur (`src/gb/`) ne dépend d'aucune bibliothèque graphique. Il se teste donc sans fenêtre et pourra plus tard être compilé en WebAssembly. Le frontend importe `gb`, jamais l'inverse.

## ROMs

Aucune ROM commerciale n'est versionnée : `roms/` et les sauvegardes `*.sav` sont dans le `.gitignore`. Les ROMs de test (Blargg, mooneye, dmg-acid2…) iront dans `test-roms/`. Elles seront téléchargées par un script, pas committées.

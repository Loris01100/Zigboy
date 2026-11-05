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

Le harnais ([tests/sst.zig](tests/sst.zig)) branche le CPU sur une mémoire plate de 64 Kio, comme le demandent ces tests. Il affiche le détail du premier cas faux de chaque opcode.

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

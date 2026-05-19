@echo off

call npx ee-bin build --cmds=electron

npx electron . --env=local

pause
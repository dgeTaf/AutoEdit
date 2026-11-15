-- AutoEdit : calage automatique des attaques de guitare / basse (DI) sur la grille de tempo du projet.
-- Lanceur : charge AutoEdit_GUI.lua du même dossier. À ajouter dans Actions > Show action list > New action >
-- Load ReaScript...
local src = debug.getinfo(1, "S").source:sub(2)
dofile((src:match("^(.*[/\\])") or "") .. "AutoEdit_GUI.lua")

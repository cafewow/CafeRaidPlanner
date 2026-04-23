local addonName, CRP = ...
_G[addonName] = CRP

CRP.version = "0.1.0-dev"
CRP.ui = {}            -- UI submodule table (populated by UI.lua)

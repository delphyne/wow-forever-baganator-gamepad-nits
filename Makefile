# Symlink the BaganatorGamepadNits addon into the WoW: Forever AddOns folder so edits apply on /reload.
#
# The folder is discovered by find-wow-addons.sh (macOS /Applications; Linux Steam/Proton, Faugus,
# Lutris, Heroic, Bottles, Wine). Override it with WOW_ADDONS=/path/to/Interface/AddOns when the
# script finds nothing or picks the wrong install. `make where` shows what it found.
NAME = BaganatorGamepadNits

ifndef WOW_ADDONS
WOW_ADDONS := $(shell sh ./find-wow-addons.sh)
endif

.PHONY: install uninstall check test where

install: where
	mkdir -p "$(WOW_ADDONS)"
	ln -sfn "$(CURDIR)/$(NAME)" "$(WOW_ADDONS)/$(NAME)"
	@echo "Linked $(WOW_ADDONS)/$(NAME) -> $(CURDIR)/$(NAME)"

uninstall: where
	rm -f "$(WOW_ADDONS)/$(NAME)"

where:
ifeq ($(WOW_ADDONS),)
	$(error No WoW: Forever AddOns folder found; pass WOW_ADDONS=/path/to/Interface/AddOns)
else
	@echo "AddOns folder: $(WOW_ADDONS)"
endif

check:
	luajit -bl $(NAME)/$(NAME).lua > /dev/null && echo "syntax ok"

test: check
	luajit tests/walkthrough.lua $(NAME)/$(NAME).lua

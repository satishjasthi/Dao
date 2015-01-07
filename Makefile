# "ghc-build-opts.mk": a trivial GNU-Make script that calls 'cabal configure' and 'cabal build'.
# 
# Copyright (C) 2008-2014  Ramin Honary.
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program (see the file called "LICENSE"). If not, see
# <http://www.gnu.org/licenses/agpl.html>.
####################################################################################################

.PHONEY: all edit test

all: dist
	cabal build

test: dist
	cabal test

dist: Dao.cabal
	cabal configure
	@echo '----------------------------------------------------------------------------------------------------'

edit:
	vim Dao.cabal $$( find . -type f -name '*.hs' )


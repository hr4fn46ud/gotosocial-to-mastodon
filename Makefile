.PHONY: test release-check dist

test:
	python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_*.py'
	ruby -e 'Dir["tests/test_*.rb"].sort.each { |file| require File.expand_path(file) }'
	ruby -c import.rb
	python3 scripts/check.py

release-check:
	python3 scripts/check.py
	git diff --check

dist:
	python3 scripts/build_release.py

.PHONY: clean
.PHONY: tests

default: clean unit_tests

clean:
	rm -f custom_image_utils/*.pyc tests/*.pyc

unit_tests:
	python2 -m unittest discover

integration_tests:
	bash tests/test_create_custom_image.sh

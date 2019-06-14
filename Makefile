.PHONY: clean
.PHONY: tests

all: clean tests

clean:
	rm -f custom_image_utils/*.pyc
	rm -f tests/*.pyc

tests:
	python2 -m unittest discover


build:
	swiftc -O notchtint.swift -o notchtint
	codesign -f -s - --identifier com.notchtint notchtint

run: build
	./notchtint

clean:
	rm -f notchtint

.PHONY: build run clean

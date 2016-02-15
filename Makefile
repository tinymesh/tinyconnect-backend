win32:
	rm -rf ./target/win32
	mkdir -p ./target/win32
	mix compile && wine "C:\\Program Files\\erl7.2.1-32bit\\bin\\escript.exe" ./build win32
	tar xvf ./target/tinyconnect.tar.gz -C ./target/win32
	cp deps/gen_serial/priv/bin/* target/win32/lib/gen_serial-0.2/priv/bin/
	rm ./target/win32/erts-7.2.1/bin/erl.ini
	./priv/pack-7z.sh win32

win64:
	rm -rf ./target/win64
	mkdir -p ./target/win64
	mix compile && wine "C:\\Program Files\\erl7.2.1\\bin\\escript.exe" ./build win64
	tar xvf ./target/tinyconnect.tar.gz -C ./target/win64
	cp deps/gen_serial/priv/bin/* target/win32/lib/gen_serial-0.2/priv/bin/
	rm ./target/win64/erts-7.2.1/bin/erl.ini
	./priv/pack-7z.sh win64


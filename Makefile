BIN = sample-tomcat-app
WEBAPPS = sample.war
PREFIX = /usr/local

.PHONY: all clean install-bin install-webapps install

sample-tomcat-app: sample-tomcat-app.sh
	cp $< $@
	sed -i 's|@out@|$(PREFIX)|g' $@
	chmod +x $@

all: $(BIN) $(WEBAPPS)

clean:
	rm -f $(BIN)

install-bin: $(BIN)
	mkdir -p $(PREFIX)/bin/
	cp $^ $(PREFIX)/bin/

install-webapps: $(WEBAPPS)
	mkdir -p $(PREFIX)/webapps/
	cp $^ $(PREFIX)/webapps/

install: install-bin install-webapps

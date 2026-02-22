PREFIX = /usr/local
BUILD_DIR = build

# Find CATALINA_HOME by resolving catalina.sh from PATH
CATALINA_HOME ?= $(shell catalina=$$(command -v catalina.sh 2>/dev/null) && real=$$(readlink "$$catalina" 2>/dev/null || echo "$$catalina") && cd "$$(dirname "$$real")/.." 2>/dev/null && pwd -P)
SERVLET_API = $(CATALINA_HOME)/lib/servlet-api.jar

.PHONY: all clean install-bin install-webapps install

all: $(BUILD_DIR)/sample.war

$(BUILD_DIR)/classes/mypackage/Hello.class: src/mypackage/Hello.java
	mkdir -p $(BUILD_DIR)/classes
	javac -classpath "$(SERVLET_API)" -d $(BUILD_DIR)/classes $<

$(BUILD_DIR)/sample.war: sample.war $(BUILD_DIR)/classes/mypackage/Hello.class web.xml
	cp sample.war $@
	mkdir -p $(BUILD_DIR)/staging/WEB-INF/classes/mypackage
	cp $(BUILD_DIR)/classes/mypackage/Hello.class $(BUILD_DIR)/staging/WEB-INF/classes/mypackage/
	cp web.xml $(BUILD_DIR)/staging/WEB-INF/
	cd $(BUILD_DIR)/staging && jar uf ../sample.war WEB-INF/classes/mypackage/Hello.class WEB-INF/web.xml

clean:
	rm -rf $(BUILD_DIR)

install-bin: sample-tomcat-app.sh
	mkdir -p $(PREFIX)/bin/
	sed 's|@out@|$(PREFIX)|g' $< > $(PREFIX)/bin/sample-tomcat-app
	chmod +x $(PREFIX)/bin/sample-tomcat-app

install-webapps: $(BUILD_DIR)/sample.war
	mkdir -p $(PREFIX)/webapps/
	cp $< $(PREFIX)/webapps/sample.war

install: install-bin install-webapps

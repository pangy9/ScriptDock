APP_NAME := ScriptDock
APP_DIR := $(APP_NAME).app
SRCS := $(wildcard src/*.swift) $(wildcard src/Supervisor/*.swift)
MCP_SRCS := src/MCP/MCPServer.swift src/SupervisorClient.swift src/Models.swift src/TaskStore.swift src/PortInspector.swift src/ProcessRunner.swift
ICON := src/Resources/AppIcon.icns

.PHONY: all build mcp run test clean

all: build mcp

build:
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp src/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(ICON)" "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	swiftc $(SRCS) -parse-as-library -o "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	codesign -f -s - "$(APP_DIR)"
	touch "$(APP_DIR)"

mcp: build
	swiftc $(MCP_SRCS) -parse-as-library -o "$(APP_DIR)/Contents/MacOS/scriptdock-mcp" -O

run: build
	open "$(APP_DIR)"

test: build
	python3 tools/smoke_test.py

clean:
	rm -rf "$(APP_DIR)"

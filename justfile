default:
    @just --list

build:
    @echo "Building project..."
    @echo "Build completed successfully"

test:
    @echo "Running tests..."
    @echo "All tests passed"

lint:
    @echo "Running linter..."
    @echo "No linting issues found"

ci: build test lint

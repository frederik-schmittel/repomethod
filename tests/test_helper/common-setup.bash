_common_setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    PATH="${REPO_ROOT}/lib:${PATH}"
}

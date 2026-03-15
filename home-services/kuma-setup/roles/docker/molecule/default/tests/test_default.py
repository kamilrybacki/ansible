"""Testinfra tests for docker role."""


def test_docker_installed(host):
    """Verify Docker CE is installed."""
    docker = host.package("docker-ce")
    assert docker.is_installed


def test_docker_cli_installed(host):
    """Verify Docker CLI is installed."""
    cli = host.package("docker-ce-cli")
    assert cli.is_installed


def test_containerd_installed(host):
    """Verify containerd is installed."""
    containerd = host.package("containerd.io")
    assert containerd.is_installed


def test_docker_service_running(host):
    """Verify Docker service is running and enabled."""
    service = host.service("docker")
    assert service.is_running
    assert service.is_enabled


def test_docker_compose_available(host):
    """Verify docker compose plugin is available."""
    result = host.run("docker compose version")
    assert result.rc == 0

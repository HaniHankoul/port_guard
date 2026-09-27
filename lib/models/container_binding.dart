class ContainerBinding {
  const ContainerBinding(
    this.address,
    this.hostPort,
    this.protocol,
    this.id,
    this.name,
  );
  final String address;
  final int hostPort;
  final String protocol;
  final String id;
  final String name;
}

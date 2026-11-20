INSERT INTO t_template (template_id, name, source_ref, created_by)
VALUES ('tpl-devbox-base-test', 'devbox-base-test', 'artifact:rootfs@base111802', 'template-build')
ON DUPLICATE KEY UPDATE name = VALUES(name), source_ref = VALUES(source_ref),
  deleted_at = NULL;

INSERT INTO t_template_build (build_id, template_id, namespace, tag,
  vcpu, ram_mb, total_disk_mb, kernel_version, firecracker_version, envd_version,
  rootfs_ext4_object_key, rootfs_ext4_sha256, rootfs_ext4_size_bytes,
  memfile_object_key, memfile_sha256, memfile_size_bytes,
  snapfile_object_key, snapfile_sha256, snapfile_size_bytes)
VALUES ('devbox-base-test-aarch64-20261119010715', 'tpl-devbox-base-test', 'platform', 'common',
  2, 1024, 10240, 'v6.6.157', 'v1.17.0', 'v0.1.6',
  'sharedata/devbox/templates/tpl-devbox-base-test/builds/devbox-base-test-aarch64-20261119010715/rootfs.ext4.zstd', '0444c004d825dbb326e67cc24bd87b012da7675c34ee0dc09dacc7311b82d56c', 870318080,
  'sharedata/devbox/templates/tpl-devbox-base-test/builds/devbox-base-test-aarch64-20261119010715/memfile.zstd', '4e48599da0da280949230d5c6feb088befb6304a9a954a27b1028e49fb44a896', 1073741824,
  'sharedata/devbox/templates/tpl-devbox-base-test/builds/devbox-base-test-aarch64-20261119010715/snapfile', 'ac606bdf61b7efde3bd66726b4b7c2b155458d9e300d2d89ed9465b939617ef1', 13066)
ON DUPLICATE KEY UPDATE tag = VALUES(tag);

INSERT INTO t_template_alias (alias, template_id, namespace, is_name)
VALUES ('default', 'tpl-devbox-base-test', 'platform', 1)
ON DUPLICATE KEY UPDATE template_id = VALUES(template_id);

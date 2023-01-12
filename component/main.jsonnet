// main template for fluentd-forwarder
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.fluentd_forwarder;
local app_name = inv.parameters._instance;
local is_openshift = std.startsWith(inv.parameters.facts.distribution, 'openshift');
local fluentd_image = '%(registry)s/%(repository)s:%(tag)s' % params.images.fluentd;

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/name': params.namespace,
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if is_openshift then 'openshift.io/cluster-monitoring']: 'true',
    },
  },
};

local serviceaccount = kube.ServiceAccount(app_name);

local configmap = kube.ConfigMap(app_name) {
  data: {
    [e]: params.env[e]
    for e in std.objectFields(params.env)
  } + {
    'td-agent.conf': params.config % {
      [v]: params.config_vars[v]
      for v in std.objectFields(params.config_vars)
    },
  },
};

local secret = kube.Secret(app_name) {
  stringData: {
    [s]: params.secrets[s]
    for s in std.objectFields(params.secrets)
  },
};

local statefulset = kube.StatefulSet(app_name) {
  spec+: {
    replicas: params.fluentd.replicas,
    template+: {
      metadata+: {
        annotations+: {
          'checksum/config': std.md5(std.manifestJsonMinified(configmap.data)),
        },
      },
      spec+: {
        restartPolicy: 'Always',
        terminationGracePeriodSeconds: 30,
        serviceAccount: app_name,
        dnsPolicy: 'ClusterFirst',
        nodeSelector: params.fluentd.nodeselector,
        affinity: params.fluentd.affinity,
        tolerations: params.fluentd.tolerations,
        containers_:: {
          [app_name]: kube.Container(app_name) {
            image: fluentd_image,
            resources: params.fluentd.resources,
            ports_:: {
              forwarder_tcp: { protocol: 'TCP', containerPort: 24224 },
              forwarder_udp: { protocol: 'UDP', containerPort: 24224 },
            },
            env_:: {
              NODE_NAME: { fieldRef: { apiVersion: 'v1', fieldPath: 'spec.nodeName' } },
            } + {
              [std.asciiUpper(e)]: { configMapKeyRef: { name: app_name, key: e } }
              for e in std.objectFields(params.env)
            } + {
              [std.asciiUpper(s)]: { secretKeyRef: { name: app_name, key: s } }
              for s in std.objectFields(params.secrets)
            },
            livenessProbe: {
              tcpSocket: {
                port: 24224,
              },
              periodSeconds: 5,
              timeoutSeconds: 3,
              initialDelaySeconds: 10,
            },
            readinessProbe: {
              tcpSocket: {
                port: 24224,
              },
              periodSeconds: 3,
              timeoutSeconds: 2,
              initialDelaySeconds: 2,
            },
            terminationMessagePolicy: 'File',
            terminationMessagePath: '/dev/termination-log',
            volumeMounts_:: {
              buffer: { mountPath: '/fluentd/log/' },
              'fluentd-config': { readOnly: true, mountPath: '/fluentd/etc' },
            },
          },
        },
        volumes_:: {
          buffer:
            { emptyDir: {} },
          'fluentd-config':
            { configMap: { name: app_name, items: [ { key: 'td-agent.conf', path: 'fluent.conf' } ], defaultMode: 420, optional: true } },
        },
      },
    },
  },
};

local service = kube.Service(app_name) {
  target_pod:: statefulset.spec.template,
  target_container_name:: app_name,
  spec+: {
    sessionAffinity: 'None',
  },
};


// Define outputs below
{
  [if params.namespace != 'openshift-logging' then '00_namespace']: namespace,
  '11_serviceaccount': serviceaccount,
  '12_configmap': configmap,
  '13_secret': secret,
  '21_statefulset': statefulset,
  '22_service': service,
}

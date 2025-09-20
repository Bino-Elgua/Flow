const config = {
  // Database configuration
  database: {
    type: process.env.DB_TYPE || 'postgresdb',
    postgresdb: {
      host: process.env.DB_POSTGRESDB_HOST || 'postgres-service',
      port: parseInt(process.env.DB_POSTGRESDB_PORT) || 5432,
      database: process.env.DB_POSTGRESDB_DATABASE || 'n8n',
      username: process.env.DB_POSTGRESDB_USER || 'n8n',
      password: process.env.DB_POSTGRESDB_PASSWORD || 'n8n_password',
      ssl: process.env.DB_POSTGRESDB_SSL === 'true',
      schema: process.env.DB_POSTGRESDB_SCHEMA || 'public'
    }
  },

  // Redis configuration for queue management
  queue: {
    bull: {
      redis: {
        host: process.env.QUEUE_BULL_REDIS_HOST || 'redis-service',
        port: parseInt(process.env.QUEUE_BULL_REDIS_PORT) || 6379,
        password: process.env.QUEUE_BULL_REDIS_PASSWORD || '',
        db: parseInt(process.env.QUEUE_BULL_REDIS_DB) || 0,
        maxRetriesPerRequest: 3,
        retryDelayOnFailover: 100,
        enableReadyCheck: false,
        maxRetriesPerRequest: null
      }
    }
  },

  // Server configuration
  server: {
    host: process.env.N8N_HOST || '0.0.0.0',
    port: parseInt(process.env.N8N_PORT) || 5678,
    protocol: process.env.N8N_PROTOCOL || 'http',
    path: process.env.N8N_PATH || '/'
  },

  // Security configuration
  security: {
    basicAuth: {
      active: process.env.N8N_BASIC_AUTH_ACTIVE === 'true',
      user: process.env.N8N_BASIC_AUTH_USER || 'admin',
      password: process.env.N8N_BASIC_AUTH_PASSWORD || 'admin',
      hash: process.env.N8N_BASIC_AUTH_HASH === 'true'
    },
    jwtAuth: {
      active: process.env.N8N_JWT_AUTH_ACTIVE === 'true',
      jwtHeader: process.env.N8N_JWT_AUTH_HEADER || 'authorization',
      jwtHeaderValuePrefix: process.env.N8N_JWT_AUTH_HEADER_VALUE_PREFIX || 'Bearer ',
      jwksUri: process.env.N8N_JWKS_URI || '',
      jwtIssuer: process.env.N8N_JWT_ISSUER || '',
      jwtNamespace: process.env.N8N_JWT_NAMESPACE || '',
      jwtAllowedTenantKey: process.env.N8N_JWT_ALLOWED_TENANT_KEY || '',
      jwtAllowedTenant: process.env.N8N_JWT_ALLOWED_TENANT || ''
    },
    excludeEndpoints: process.env.N8N_AUTH_EXCLUDE_ENDPOINTS?.split(':') || [
      'healthz',
      'metrics'
    ]
  },

  // Webhook configuration
  webhooks: {
    url: process.env.WEBHOOK_URL || 'http://localhost:5678/',
    urlSuffix: process.env.WEBHOOK_URL_SUFFIX || '',
    waitingWebhooks: {
      maxWaitTime: parseInt(process.env.N8N_WAITING_WEBHOOKS_MAX_WAIT_TIME) || 120
    }
  },

  // Execution configuration
  executions: {
    mode: process.env.EXECUTIONS_MODE || 'queue',
    timeout: parseInt(process.env.EXECUTIONS_TIMEOUT) || 3600,
    maxTimeout: parseInt(process.env.EXECUTIONS_TIMEOUT_MAX) || 3600,
    saveDataOnError: process.env.EXECUTIONS_DATA_SAVE_ON_ERROR || 'all',
    saveDataOnSuccess: process.env.EXECUTIONS_DATA_SAVE_ON_SUCCESS || 'all',
    saveDataManualExecutions: process.env.EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS === 'true',
    pruneData: process.env.EXECUTIONS_DATA_PRUNE === 'true',
    pruneDataMaxAge: parseInt(process.env.EXECUTIONS_DATA_MAX_AGE) || 168, // hours
    pruneDataTimeout: parseInt(process.env.EXECUTIONS_DATA_PRUNE_TIMEOUT) || 3600 // seconds
  },

  // Generic configuration
  generic: {
    timezone: process.env.GENERIC_TIMEZONE || 'UTC'
  },

  // Logging configuration
  logs: {
    level: process.env.N8N_LOG_LEVEL || 'info',
    output: process.env.N8N_LOG_OUTPUT || 'console',
    file: {
      location: process.env.N8N_LOG_FILE_LOCATION || '/home/node/.n8n/logs/',
      fileSizeMax: parseInt(process.env.N8N_LOG_FILE_SIZE_MAX) || 16, // MB
      fileCountMax: parseInt(process.env.N8N_LOG_FILE_COUNT_MAX) || 100
    }
  },

  // Metrics configuration
  metrics: {
    enable: process.env.N8N_METRICS === 'true',
    prefix: process.env.N8N_METRICS_PREFIX || 'n8n_'
  },

  // Workflow configuration
  workflows: {
    defaultName: process.env.N8N_DEFAULT_NAME || 'My workflow',
    onboardingFlowDisabled: process.env.N8N_ONBOARDING_FLOW_DISABLED === 'true',
    callerPolicyDefaultOption: process.env.N8N_WORKFLOW_CALLER_POLICY_DEFAULT_OPTION || 'workflowsFromSameOwner'
  },

  // User management configuration
  userManagement: {
    disabled: process.env.N8N_USER_MANAGEMENT_DISABLED === 'true',
    jwtSecret: process.env.N8N_USER_MANAGEMENT_JWT_SECRET || 'n8n-user-jwt-secret',
    jwtSessionDuration: parseInt(process.env.N8N_USER_MANAGEMENT_JWT_DURATION_HOURS) || 168, // hours
    jwtRefreshTimeoutHours: parseInt(process.env.N8N_USER_MANAGEMENT_JWT_REFRESH_TIMEOUT_HOURS) || 24
  },

  // Email configuration for notifications
  email: {
    mode: process.env.N8N_EMAIL_MODE || 'smtp',
    smtp: {
      host: process.env.N8N_SMTP_HOST || '',
      port: parseInt(process.env.N8N_SMTP_PORT) || 587,
      user: process.env.N8N_SMTP_USER || '',
      pass: process.env.N8N_SMTP_PASS || '',
      sender: process.env.N8N_SMTP_SENDER || '',
      ssl: process.env.N8N_SMTP_SSL === 'true'
    }
  },

  // External secrets configuration
  externalSecrets: {
    preferGet: process.env.N8N_EXTERNAL_SECRETS_PREFER_GET === 'true',
    updateInterval: parseInt(process.env.N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL) || 300 // seconds
  },

  // Version notifications
  versionNotifications: {
    enabled: process.env.N8N_VERSION_NOTIFICATIONS_ENABLED !== 'false',
    endpoint: process.env.N8N_VERSION_NOTIFICATIONS_ENDPOINT || 'https://api.n8n.io/versions/',
    infoUrl: process.env.N8N_VERSION_NOTIFICATIONS_INFO_URL || 'https://docs.n8n.io/getting-started/installation/updating/'
  }
};

module.exports = config;
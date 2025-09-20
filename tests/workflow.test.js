const axios = require('axios');
const fs = require('fs');
const path = require('path');

// Test configuration
const TEST_CONFIG = {
  n8nUrl: process.env.N8N_URL || 'http://localhost:5678',
  basicAuth: {
    username: process.env.N8N_BASIC_AUTH_USER || 'admin',
    password: process.env.N8N_BASIC_AUTH_PASSWORD || 'admin'
  },
  timeout: 30000
};

// Create axios instance with default config
const api = axios.create({
  baseURL: TEST_CONFIG.n8nUrl,
  timeout: TEST_CONFIG.timeout,
  auth: TEST_CONFIG.basicAuth
});

/**
 * Test suite for n8n workflows
 */
class WorkflowTester {
  constructor() {
    this.results = {
      passed: 0,
      failed: 0,
      errors: []
    };
  }

  /**
   * Log test results
   */
  log(message, type = 'info') {
    const timestamp = new Date().toISOString();
    const prefix = {
      info: 'ℹ️',
      success: '✅',
      error: '❌',
      warning: '⚠️'
    }[type] || 'ℹ️';
    
    console.log(`[${timestamp}] ${prefix} ${message}`);
  }

  /**
   * Assert condition and update results
   */
  assert(condition, message) {
    if (condition) {
      this.results.passed++;
      this.log(`PASS: ${message}`, 'success');
    } else {
      this.results.failed++;
      this.results.errors.push(message);
      this.log(`FAIL: ${message}`, 'error');
    }
  }

  /**
   * Test n8n health endpoint
   */
  async testHealthEndpoint() {
    this.log('Testing n8n health endpoint...');
    
    try {
      const response = await api.get('/healthz');
      this.assert(response.status === 200, 'Health endpoint returns 200');
      this.assert(response.data && response.data.status === 'ok', 'Health endpoint returns OK status');
    } catch (error) {
      this.assert(false, `Health endpoint test failed: ${error.message}`);
    }
  }

  /**
   * Test n8n API endpoints
   */
  async testApiEndpoints() {
    this.log('Testing n8n API endpoints...');
    
    try {
      // Test workflows endpoint
      const workflowsResponse = await api.get('/api/v1/workflows');
      this.assert(workflowsResponse.status === 200, 'Workflows endpoint accessible');

      // Test credentials endpoint
      const credentialsResponse = await api.get('/api/v1/credentials');
      this.assert(credentialsResponse.status === 200, 'Credentials endpoint accessible');

      // Test executions endpoint
      const executionsResponse = await api.get('/api/v1/executions');
      this.assert(executionsResponse.status === 200, 'Executions endpoint accessible');
    } catch (error) {
      this.assert(false, `API endpoints test failed: ${error.message}`);
    }
  }

  /**
   * Validate workflow JSON structure
   */
  validateWorkflowStructure(workflow) {
    const requiredFields = ['name', 'nodes', 'connections', 'active', 'settings'];
    const missingFields = requiredFields.filter(field => !(field in workflow));
    
    this.assert(missingFields.length === 0, `Workflow has all required fields (missing: ${missingFields.join(', ')})`);
    this.assert(Array.isArray(workflow.nodes), 'Workflow nodes is an array');
    this.assert(typeof workflow.connections === 'object', 'Workflow connections is an object');
    this.assert(typeof workflow.active === 'boolean', 'Workflow active is a boolean');
    this.assert(typeof workflow.settings === 'object', 'Workflow settings is an object');
  }

  /**
   * Test workflow file validation
   */
  async testWorkflowFiles() {
    this.log('Testing workflow files...');
    
    const workflowsDir = path.join(__dirname, '../workflows');
    
    try {
      const files = fs.readdirSync(workflowsDir);
      const jsonFiles = files.filter(file => file.endsWith('.json'));
      
      this.assert(jsonFiles.length > 0, 'At least one workflow file exists');
      
      for (const file of jsonFiles) {
        const filePath = path.join(workflowsDir, file);
        const content = fs.readFileSync(filePath, 'utf8');
        
        try {
          const workflow = JSON.parse(content);
          this.assert(true, `${file} is valid JSON`);
          this.validateWorkflowStructure(workflow);
        } catch (parseError) {
          this.assert(false, `${file} is invalid JSON: ${parseError.message}`);
        }
      }
    } catch (error) {
      this.assert(false, `Workflow files test failed: ${error.message}`);
    }
  }

  /**
   * Test workflow import
   */
  async testWorkflowImport() {
    this.log('Testing workflow import...');
    
    try {
      const workflowPath = path.join(__dirname, '../workflows/verifi.json');
      
      if (!fs.existsSync(workflowPath)) {
        this.assert(false, 'Verifi workflow file not found');
        return;
      }
      
      const workflowContent = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
      
      // Remove ID to allow creation of new workflow
      delete workflowContent.id;
      
      const response = await api.post('/api/v1/workflows', workflowContent);
      this.assert(response.status === 201, 'Workflow import successful');
      
      if (response.status === 201) {
        const workflowId = response.data.id;
        this.log(`Imported workflow with ID: ${workflowId}`);
        
        // Clean up - delete the test workflow
        try {
          await api.delete(`/api/v1/workflows/${workflowId}`);
          this.log('Test workflow cleaned up');
        } catch (cleanupError) {
          this.log('Failed to clean up test workflow', 'warning');
        }
      }
    } catch (error) {
      this.assert(false, `Workflow import test failed: ${error.message}`);
    }
  }

  /**
   * Test webhook endpoints
   */
  async testWebhookEndpoints() {
    this.log('Testing webhook endpoints...');
    
    try {
      // Test webhook endpoint (even if no workflow is active)
      const webhookResponse = await api.post('/webhook/test', { test: true });
      // Webhook might return 404 if no workflow is listening, which is fine
      this.assert(
        webhookResponse.status === 200 || webhookResponse.status === 404,
        'Webhook endpoint responds (200 or 404 expected)'
      );
    } catch (error) {
      // 404 is expected if no webhook workflow is active
      if (error.response && error.response.status === 404) {
        this.assert(true, 'Webhook endpoint accessible (404 expected without active webhook)');
      } else {
        this.assert(false, `Webhook test failed: ${error.message}`);
      }
    }
  }

  /**
   * Test database connectivity
   */
  async testDatabaseConnectivity() {
    this.log('Testing database connectivity...');
    
    try {
      // Try to get workflows (which requires DB access)
      const response = await api.get('/api/v1/workflows');
      this.assert(response.status === 200, 'Database connectivity verified via workflows endpoint');
    } catch (error) {
      this.assert(false, `Database connectivity test failed: ${error.message}`);
    }
  }

  /**
   * Run all tests
   */
  async runAllTests() {
    this.log('Starting n8n workflow tests...', 'info');
    
    try {
      await this.testHealthEndpoint();
      await this.testApiEndpoints();
      await this.testWorkflowFiles();
      await this.testDatabaseConnectivity();
      await this.testWebhookEndpoints();
      
      // Only test import if n8n is running
      if (this.results.passed > 0) {
        await this.testWorkflowImport();
      }
      
    } catch (error) {
      this.log(`Unexpected error during testing: ${error.message}`, 'error');
      this.results.failed++;
      this.results.errors.push(error.message);
    }
    
    // Print summary
    this.printSummary();
    
    // Exit with appropriate code
    process.exit(this.results.failed > 0 ? 1 : 0);
  }

  /**
   * Print test summary
   */
  printSummary() {
    this.log('', 'info');
    this.log('=== TEST SUMMARY ===', 'info');
    this.log(`Passed: ${this.results.passed}`, 'success');
    this.log(`Failed: ${this.results.failed}`, this.results.failed > 0 ? 'error' : 'info');
    
    if (this.results.errors.length > 0) {
      this.log('', 'info');
      this.log('Errors:', 'error');
      this.results.errors.forEach(error => {
        this.log(`  - ${error}`, 'error');
      });
    }
    
    this.log('', 'info');
    const status = this.results.failed === 0 ? 'PASSED' : 'FAILED';
    this.log(`Overall status: ${status}`, this.results.failed === 0 ? 'success' : 'error');
  }
}

// Run tests if this file is executed directly
if (require.main === module) {
  const tester = new WorkflowTester();
  tester.runAllTests();
}

module.exports = WorkflowTester;
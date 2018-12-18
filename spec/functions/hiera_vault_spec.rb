require 'spec_helper'
require 'support/vault_server'
require 'puppet/functions/hiera_vault'

describe FakeFunction do
  let :function do
    described_class.new
  end

  let :context do
    ctx = instance_double('Puppet::LookupContext')
    allow(ctx).to receive(:cache_has_key).and_return(false)
    if ENV['DEBUG']
      allow(ctx).to receive(:explain) { |&block| puts(block.call) }
    else
      allow(ctx).to receive(:explain).and_return(:nil)
    end
    allow(ctx).to receive(:not_found)
    allow(ctx).to receive(:cache).with(String, anything) do |_, val|
      val
    end
    allow(ctx).to receive(:interpolate).with(anything) do |val|
      val
    end
    ctx
  end

  let :vault_options do
    {
      'address' => RSpec::VaultServer.address,
      'token' => RSpec::VaultServer.token,
      'mounts' => {
        'kv' => [
          'puppet'
        ]
      }
    }
  end

  def vault_test_client
    Vault::Client.new(
      address: RSpec::VaultServer.address,
      token: RSpec::VaultServer.token
    )
  end

  describe '#lookup_key' do
    context 'accessing vault' do
      context 'supplied with invalid parameters' do
        it 'should error when default_field_parse is not in [ string, json ]' do
          expect { function.lookup_key('test_key', vault_options.merge('default_field_parse' => 'invalid'), context) }
            .to raise_error(ArgumentError, '[hiera-vault] invalid value for default_field_parse: \'invalid\', should be one of \'string\',\'json\'')
        end

        it 'should error when default_field_behavior is not in [ ignore, only ]' do
          expect { function.lookup_key('test_key', vault_options.merge('default_field_behavior' => 'invalid'), context) }
            .to raise_error(ArgumentError, '[hiera-vault] invalid value for default_field_behavior: \'invalid\', should be one of \'ignore\',\'only\'')
        end

        it 'should error when confine_to_keys is no array' do
          expect { function.lookup_key('test_key', { 'confine_to_keys' => '^vault.*$' }, context) }
            .to raise_error(ArgumentError, '[hiera-vault] confine_to_keys must be an array')
        end

        it 'should error when passing invalid regexes' do
          expect { function.lookup_key('test_key', { 'confine_to_keys' => ['['] }, context) }
            .to raise_error(Puppet::DataBinding::LookupError, '[hiera-vault] creating regexp failed with: premature end of char-class: /[/')
        end

        it 'should error when token isnst specified' do
          expect { function.lookup_key('test_key', vault_options.merge('token' => nil), context) }
            .to raise_error(ArgumentError, '[hiera-vault] no token set in options and no token in VAULT_TOKEN')
        end
      end

      context 'when vault is sealed' do
        before(:context) do
          vault_test_client.sys.seal
        end
        it 'should raise error for Vault being sealed' do
          expect { function.lookup_key('test_key', vault_options, context) }
            .to raise_error(Puppet::DataBinding::LookupError, '[hiera-vault] Skipping backend. Configuration error: [hiera-vault] vault is sealed')
        end
        after(:context) do
          vault_test_client.sys.unseal(RSpec::VaultServer.unseal_token)
        end
      end

      context 'when vault is unsealed' do
        before(:context) do
          vault_test_client.sys.mount('puppet', 'kv', 'puppet secrets')
          vault_test_client.logical.write('puppet/test_key', value: 'default')
          vault_test_client.logical.write('puppet/array_key', value: '["a", "b", "c"]')
          vault_test_client.logical.write('puppet/hash_key', value: '{"a": 1, "b": 2, "c": 3}')
          vault_test_client.logical.write('puppet/multiple_values_key', a: 1, b: 2, c: 3)
          vault_test_client.logical.write('puppet/values_key', value: 123, a: 1, b: 2, c: 3)
          vault_test_client.logical.write('puppet/broken_json_key', value: '[,')
          vault_test_client.logical.write('puppet/confined_vault_key', value: 'find_me')
        end

        context 'configuring vault' do
          let :context do
            ctx = instance_double('Puppet::LookupContext')
            allow(ctx).to receive(:cache_has_key).and_return(false)
            allow(ctx).to receive(:explain) { |&block| puts(block.call) }
            allow(ctx).to receive(:not_found)
            allow(ctx).to receive(:cache).with(String, anything) do |_, val|
              val
            end
            allow(ctx).to receive(:interpolate).with(anything) do |val|
              val
            end
            ctx
          end

          it 'should exit early if ENV VAULT_TOKEN is set to IGNORE-VAULT' do
            ENV['VAULT_TOKEN'] = 'IGNORE-VAULT'
            expect(context).to receive(:not_found)
            expect { function.lookup_key('test_key', vault_options.merge({'token' => nil}), context) }.
              to output(/token set to IGNORE-VAULT - Quitting early/).to_stdout
          end

          it 'should exit early if token is set to IGNORE-VAULT' do
            expect(context).to receive(:not_found)
            expect { function.lookup_key('test_key', vault_options.merge({'token' => 'IGNORE-VAULT'}), context) }.
              to output(/token set to IGNORE-VAULT - Quitting early/).to_stdout
          end

          it 'should allow the configuring of a vault token from a file' do
            vault_token_tmpfile = Tempfile.open('w')
            vault_token_tmpfile.puts(RSpec::VaultServer.token)
            vault_token_tmpfile.close
            expect { function.lookup_key('test_key', vault_options.merge({'token' => vault_token_tmpfile.path}), context) }.
              to output(/Read secret: test_key/).to_stdout
          end

          it 'should show error when file token is not valid' do
            vault_token_tmpfile = Tempfile.open('w')
            vault_token_tmpfile.puts('not-valid-token')
            vault_token_tmpfile.close
            expect { function.lookup_key('test_key', vault_options.merge({'token' => vault_token_tmpfile.path}), context) }.
              to output(/Could not read secret puppet\/test_key: permission denied/).to_stdout
          end
        end

        context 'reading secrets' do
          it 'should return the full key if no default_field specified' do
            expect(function.lookup_key('test_key', vault_options, context))
              .to include('value' => 'default')
          end

          it 'should return the key if regex matches confine_to_keys' do
            expect(function.lookup_key('confined_vault_key', vault_options.merge('confine_to_keys' => ['^vault.*$']), context))
              .to include('value' => 'find_me')
          end

          it 'should not return the key if regex does not match confine_to_keys' do
            expect(context).to receive(:not_found)
            expect(function.lookup_key('puppet/data/test_key', vault_options.merge('confine_to_keys' => ['^vault.*$']), context))
              .to be_nil
          end

          it 'should return nil on non-existant key' do
            expect(context).to receive(:not_found)
            expect(function.lookup_key('doesnt_exist', vault_options, context)).to be_nil
          end

          it 'should return the default_field value if present' do
            expect(function.lookup_key('test_key', { 'default_field' => 'value' }.merge(vault_options), context))
              .to eq('default')
          end

          it 'should return a hash lacking a default field' do
            expect(function.lookup_key('multiple_values_key', vault_options, context))
              .to include('a' => 1, 'b' => 2, 'c' => 3)
          end

          it 'should return an array parsed from json' do
            expect(function.lookup_key('array_key', {
              'default_field' => 'value',
              'default_field_parse' => 'json'
            }.merge(vault_options), context))
              .to contain_exactly('a', 'b', 'c')
          end

          it 'should return a hash parsed from json' do
            expect(function.lookup_key('hash_key', {
              'default_field' => 'value',
              'default_field_parse' => 'json'
            }.merge(vault_options), context))
              .to include('a' => 1, 'b' => 2, 'c' => 3)
          end

          it 'should return the string value on broken json content' do
            expect(function.lookup_key('broken_json_key', {
              'default_field' => 'value',
              'default_field_parse' => 'json'
            }.merge(vault_options), context))
              .to eq('[,')
          end

          it 'should return *only* the default_field value if present' do
            expect(function.lookup_key('test_key', {
              'default_field' => 'value',
              'default_field_behavior' => 'only'
            }.merge(vault_options), context))
              .to eq('default')

            expect(function.lookup_key('values_key', {
              'default_field' => 'value',
              'default_field_behavior' => 'only'
            }.merge(vault_options), context))
              .to include('a' => 1, 'b' => 2, 'c' => 3, 'value' => 123)
            expect(function.lookup_key('values_key', {
              'default_field' => 'value'
            }.merge(vault_options), context))
              .to eq(123)
          end

          it 'should return nil with value field not existing and default_field_behavior set to ignore' do
            expect(function.lookup_key('multiple_values_key', {
              'default_field' => 'value',
              'default_field_behavior' => 'ignore'
            }.merge(vault_options), context))
              .to be_nil
          end
        end
      end
    end
  end
end

require 'spec_helper'

describe Bosh::AwsCloud::Cloud do
  subject(:cloud) { described_class.new(options) }
  let(:aws_options) do
    {
      'access_key_id' => 'keys to my heart',
      'secret_access_key' => 'open sesame',
      'region' => 'fake-region',
      'default_key_name' => 'sesame',
    }
  end
  let(:options) do
    {
      'aws' => aws_options,
      'registry' => {
        'user' => 'abuser',
        'password' => 'hard2gess',
        'endpoint' => 'http://websites.com'
      }
    }
  end

  let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector') }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
    reg = AWS::EC2::Region.new('some-region', endpoint: 'http://some.endpoint')
    allow_any_instance_of(AWS::EC2).to receive(:regions).and_return([reg])
  end

  describe '#initialize' do
    describe 'validating initialization options' do
      context 'when options are invalid' do
        let(:options) do
          {
            'aws' => {
              'access_key_id' => 'keys to my heart',
              'secret_access_key' => 'open sesame'
            }
          }
        end

        it 'raises an error' do
          expect { cloud }.to raise_error(
              ArgumentError,
              'missing configuration parameters > aws:region, aws:default_key_name, registry:endpoint, registry:user, registry:password'
            )
        end
      end

      context 'when all the required configurations are present' do
        it 'does not raise an error ' do
          expect { cloud }.to_not raise_error
        end
      end

      context 'when optional properties are not provided' do
        it 'default value is used for max retries' do
          expect(cloud.ec2.config.max_retries).to be 2
        end

        it 'default value is used for http properties' do
          expect(cloud.ec2.config.http_read_timeout).to eq(60)
          expect(cloud.ec2.config.http_wire_trace).to be false
          expect(cloud.ec2.config.ssl_verify_peer).to be true
        end
      end

      context 'when optional and required properties are provided' do
        let(:options) do
          {
            'aws' => {
              'access_key_id' => 'keys to my heart',
              'secret_access_key' => 'open sesame',
              'region' => 'fake-region',
              'default_key_name' => 'sesame',
              'http_read_timeout' => 300,
              'http_wire_trace' => true,
              'ssl_verify_peer' => false,
              'ssl_ca_file' => '/custom/cert/ca-certificates',
              'ssl_ca_path' => '/custom/cert/'
            },
            'registry' => {
              'user' => 'abuser',
              'password' => 'hard2gess',
              'endpoint' => 'http://websites.com'
            }
          }
        end

        it 'passes required properties to AWS SDK' do
          config = cloud.ec2.config
          expect(config.access_key_id).to eq('keys to my heart')
          expect(config.secret_access_key).to eq('open sesame')
          expect(config.region).to eq('fake-region')
        end
        it 'passes optional properties to AWS SDK' do
          config = cloud.ec2.config
          expect(config.http_read_timeout).to eq(300)
          expect(config.http_wire_trace).to be true
          expect(config.ssl_verify_peer).to be false
          expect(config.ssl_ca_file).to eq('/custom/cert/ca-certificates')
          expect(config.ssl_ca_path).to eq('/custom/cert/')
        end
      end
    end

    context 'when there is no proper network access to AWS' do
      before do
        allow_any_instance_of(AWS::EC2).to receive(:regions).and_raise(Net::OpenTimeout, 'execution expired')
      end

      it 'raises an exception with a user friendly message' do
        expect { cloud }.to raise_error(Bosh::Clouds::CloudError, 'Please make sure the CPI has proper network access to AWS. #<Net::OpenTimeout: execution expired>')
      end
    end
  end

  describe '#create_disk' do
    let(:cloud_properties) { {} }
    let(:volume) { instance_double('AWS::EC2::Volume', id: 'fake-volume-id') }

    before do
      allow(az_selector).to receive(:select_availability_zone).
        with(42).and_return('fake-availability-zone')
    end

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume).with(volume: volume, state: :available)
    end

    context 'when volumes are set' do
      let(:ec2) { instance_double('AWS::EC2', volumes: volumes) }
      let(:volumes) { instance_double('AWS::EC2::VolumeCollection') }
      before { cloud.instance_variable_set(:'@ec2', ec2) }

      context 'when disk type is provided' do
        let(:cloud_properties) { { 'type' => disk_type } }

        context 'when disk size is between 1 GiB and 16 TiB' do
          let(:disk_size) { 10240000 }

          context 'when disk type is not gp2, io1, or standard' do
            let(:disk_type) { 'non-existing-disk-type' }

            it 'raises an error' do
              expect {
                cloud.create_disk(disk_size, cloud_properties, 42)
              }.to raise_error /AWS CPI supports only gp2, io1, or standard disk type/
            end
          end

          context 'when disk type is gp2' do
            let(:disk_type) { 'gp2' }

            it 'creates disk with gp2 type' do
              expect(volumes).to receive(:create).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'gp2',
                encrypted: false
              ).and_return(volume)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end

            it 'raises an error when iops is provided' do
              cloud_properties = { 'type' => disk_type, 'iops' => 1 }
              expect {
                cloud.create_disk(disk_size, cloud_properties, 42)
              }.to raise_error(
                Bosh::Clouds::CloudError,
                "Cannot specify an 'iops' value when disk type is '#{disk_type}'. 'iops' is only allowed for 'io1' volume types."
              )
            end
          end

          context 'when disk type is io1' do
            let(:cloud_properties) { { 'type' => disk_type, 'iops' => 123 } }
            let(:disk_type) { 'io1' }

            it 'creates disk with io1 type' do
              expect(volumes).to receive(:create).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'io1',
                iops: 123,
                encrypted: false
              ).and_return(volume)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end

            it 'raises an error when iops is omitted' do
              cloud_properties = { 'type' => disk_type }
              expect {
                cloud.create_disk(disk_size, cloud_properties, 42)
              }.to raise_error(
                Bosh::Clouds::CloudError,
                "Must specify an 'iops' value when the volume type is '#{disk_type}'"
              )
            end
          end
        end

        context 'when disk size is between 1 GiB and 1 TiB' do
          let(:disk_size) { 1025 }

          context 'when disk type is standard' do
            let(:disk_type) { 'standard' }

            it 'creates disk with standard type' do
              expect(volumes).to receive(:create).with(
                size: 2,
                availability_zone: 'fake-availability-zone',
                volume_type: 'standard',
                encrypted: false
              ).and_return(volume)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end

            it 'raises an error when iops is provided' do
              cloud_properties = { 'type' => disk_type, 'iops' => 1 }
              expect {
                cloud.create_disk(disk_size, cloud_properties, 42)
              }.to raise_error(
                Bosh::Clouds::CloudError,
                "Cannot specify an 'iops' value when disk type is '#{disk_type}'. 'iops' is only allowed for 'io1' volume types."
              )
            end
          end
        end
      end

      context 'when disk type is not provided' do
        let(:cloud_properties) { {} }
        let(:disk_size) { 1025 }

        it 'creates disk with standard disk type' do
          expect(volumes).to receive(:create).with(
            size: 2,
            availability_zone: 'fake-availability-zone',
            volume_type: 'standard',
            encrypted: false
          ).and_return(volume)
          cloud.create_disk(disk_size, cloud_properties, 42)
        end
      end
    end
  end

  describe 'validating credentials_source' do
    context 'when credentials_source is set to static' do

      context 'when access_key_id and secret_access_key are omitted' do
        let(:options) do
          {
            'aws' => {
              'credentials_source' => 'static',
              'access_key_id' => nil,
              'secret_access_key' => nil,
              'region' => 'fake-region',
              'default_key_name' => 'sesame'
            },
            'registry' => {
              'user' => 'abuser',
              'password' => 'hard2gess',
              'endpoint' => 'http://websites.com'
            }
          }
        end
        it 'raises an error' do
          expect { cloud }.to raise_error(
          ArgumentError,
          'Must use access_key_id and secret_access_key with static credentials_source'
          )
        end
      end
    end

    context 'when credentials_source is set to env_or_profile' do
      let(:options) do
        {
          'aws' => {
            'credentials_source' => 'env_or_profile',
            'access_key_id' => nil,
            'secret_access_key' => nil,
            'region' => 'fake-region',
            'default_key_name' => 'sesame'
          },
          'registry' => {
            'user' => 'abuser',
            'password' => 'hard2gess',
            'endpoint' => 'http://websites.com'
          }
        }
      end
      it 'does not raise an error ' do
        expect { cloud }.to_not raise_error
      end
    end

    context 'when credentials_source is set to env_or_profile and access_key_id is provided' do
      let(:options) do
        {
          'aws' => {
            'credentials_source' => 'env_or_profile',
            'access_key_id' => 'some access key',
            'region' => 'fake-region',
            'default_key_name' => 'sesame'
          },
          'registry' => {
            'user' => 'abuser',
            'password' => 'hard2gess',
            'endpoint' => 'http://websites.com'
          }
        }
      end
      it 'raises an error' do
        expect { cloud }.to raise_error(
        ArgumentError,
        "Can't use access_key_id and secret_access_key with env_or_profile credentials_source"
        )
      end
    end

    context 'when an unknown credentails_source is set' do
      let(:options) do
        {
          'aws' => {
            'credentials_source' => 'NotACredentialsSource',
            'region' => 'fake-region',
            'default_key_name' => 'sesame'
          },
          'registry' => {
            'user' => 'abuser',
            'password' => 'hard2gess',
            'endpoint' => 'http://websites.com'
          }
        }
      end

      it 'raises an error' do
        expect { cloud }.to raise_error(
        ArgumentError,
        'Unknown credentials_source NotACredentialsSource'
        )
      end
    end
  end
end

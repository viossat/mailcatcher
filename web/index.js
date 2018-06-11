import React from 'react'
import ReactDOM from 'react-dom'
import classNames from 'classnames'
import { DateTime } from 'luxon'
import prettyBytes from 'pretty-bytes'

class Toolbar extends React.PureComponent {
  render() {
    return (
      <div className="Toolbar">{this.props.children}</div>
    )
  }
}

class ToolbarSpacer extends React.PureComponent {
  render() {
    return (
      <div className="ToolbarSpacer"></div>
    )
  }
}

class ToolbarTitle extends React.PureComponent {
  render() {
    return (
      <div className="ToolbarTitle">{this.props.text}</div>
    )
  }
}

class ToolbarButton extends React.PureComponent {
  render() {
    return (
      <button className="ToolbarButton" onClick={this.props.onClick}>{this.props.text}</button>
    )
  }
}

class MessagesList extends React.PureComponent {
  state = {
    messages: null,
    selectedMessageId: null,
  }

  async componentWillMount() {
    var response = await fetch("./messages")
    var json = await response.text()
    var messages = JSON.parse(json)
    this.setState({messages})
  }

  render() {
    if (this.state.messages === null) {
      return <div className="MessagesList loading">
        <div className="MessagesList-loader">Loading...</div>
      </div>
    } else {
      return <div className="MessagesList">{this.renderMessages()}</div>
    }
  }

  renderMessages() {
    return <div className="MessagesList-messages">
      <table border="0" cellPadding="0" cellSpacing="0" width="100%">
        <thead>
          <tr>
            <th>Sender</th>
            <th>Recipients</th>
            <th>Subject</th>
            <th>Received</th>
            <th>Size</th>
          </tr>
        </thead>
        <tbody>
          {this.state.messages.map(message => this.renderMessageRow(message))}
        </tbody>
      </table>
    </div>
  }

  onClickMessageRow = (e) => {
    const row = e.currentTarget
    this.setState({selectedMessageId: row.dataset['id']})
  }

  renderMessageRow(message) {
    return (
      <tr key={message.id} className={classNames("MessageList-row", {selected: this.state.selectedMessageId == message.id})} onClick={this.onClickMessageRow} data-id={message.id}>
        <td>{message.sender}</td>
        <td>{message.recipients}</td>
        <td>{message.subject}</td>
        <td nowrap="nowrap">{DateTime.fromISO(message.created_at).toLocaleString(DateTime.DATETIME_FULL)}</td>
        <td nowrap="nowrap">{prettyBytes(message.size)}</td>
      </tr>
    )
  }
}

class MessageFrame extends React.PureComponent {
  render() {
    return (
      <div className="MessageFrame"></div>
    )
  }
}

class Root extends React.PureComponent {
  handleQuitClick = () => {
    fetch("./", {method: "DELETE"})
      .then(() => document.location.href = "https://mailcatcher.me")
  }

  render() {
    return (
      <div className="Root">
        <Toolbar>
          <ToolbarTitle text="MailCatcher" />
          <ToolbarSpacer />
          <ToolbarButton text="Quit" onClick={this.handleQuitClick} />
        </Toolbar>
        <MessagesList />
        <MessageFrame />
      </div>
    )
  }
}

ReactDOM.render(<Root />, document.getElementById('root'))
